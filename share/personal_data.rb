require "json"
require "yaml"
require "open3"

module RimeDeploy
  class PersonalData
    def initialize(path = Store.config_path, backup_root: File.expand_path("../personal-data", __dir__), manager: nil)
      @path = File.expand_path(path)
      @backup_root = File.expand_path(backup_root)
      @manager = manager
    end

    def bundles
      return [] unless File.directory?(@backup_root)
      Dir.children(@backup_root).sort.reverse.map { |name| File.join(@backup_root, name) }.select do |directory|
        File.directory?(directory) && !File.symlink?(directory) && File.file?(File.join(directory, "manifest.json"))
      end
    end

    def export(prefix: "export-", extra_files: [])
      require_data_directory
      names = Dir.glob("*.userdb", base: @path).sort.map do |entry|
        name = entry.delete_suffix(".userdb")
        validate_dictionary_name(name)
        directory = checked_path(@path, entry)
        raise RimeDeployError, "Unsupported user dictionary: #{directory}" unless File.directory?(directory)
        name
      end
      files = (personal_files + extra_files).uniq.sort
      files.each { |relative| validate_data_file(relative); checked_path(@path, relative, file: true) }
      sync_directory, installation_id = sync_settings unless names.empty?
      dict_manager unless names.empty?
      raise RimeDeployError, "Backup directory must not be a symlink." if File.symlink?(@backup_root)
      FileUtils.mkdir_p(@backup_root)
      bundle = Dir.mktmpdir(prefix, @backup_root)
      complete = false
      begin
        names.each do |name|
          snapshot = checked_path(sync_directory, "#{installation_id}/#{name}.userdb.txt")
          destination = File.join(bundle, "dictionaries", "#{name}.userdb.txt")
          FileUtils.mkdir_p(File.dirname(destination))
          backup_dictionary(name, snapshot, destination)
        end
        files.each do |relative|
          destination = File.join(bundle, "files", relative)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(checked_path(@path, relative, file: true), destination)
        end
        manifest = {"version" => 1, "dictionaries" => names, "files" => files}
        File.write(File.join(bundle, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
        complete = true
        puts "Saved #{names.length} user dictionaries and #{files.length} personal files to #{bundle}"
        bundle
      ensure
        FileUtils.remove_entry(bundle) unless complete
      end
    end

    def restore(bundle)
      require_data_directory
      manifest = load_bundle(bundle)
      manifest.fetch("files").each do |relative|
        target = checked_path(@path, relative)
        if File.exist?(target) && !File.file?(target)
          raise RimeDeployError, "Refusing to replace a non-regular file: #{target}"
        end
      end
      unless manifest.fetch("dictionaries").empty?
        require_restore_workspace
        sync_settings
        dict_manager
      end
      existing_files = manifest.fetch("files").select { |relative| File.file?(File.join(@path, relative)) }
      backup = export(prefix: "before-restore-", extra_files: existing_files)
      puts "Before-restore backup: #{backup}"
      manifest.fetch("dictionaries").each do |name|
        require_restore_workspace
        run_manager("--restore", checked_path(bundle, "dictionaries/#{name}.userdb.txt", file: true))
      end
      manifest.fetch("files").each do |relative|
        source = checked_path(bundle, "files/#{relative}", file: true)
        target = checked_path(@path, relative)
        FileUtils.mkdir_p(File.dirname(target))
        Tempfile.create([".rime-restore-", ".tmp"], File.dirname(target)) do |file|
          file.close
          FileUtils.cp(source, file.path)
          File.rename(file.path, target)
        end
      end
      puts "User dictionaries were merged; phrase and dictionary files were restored. Redeploy Rime."
      puts "Custom dictionaries must be referenced by the target machine's dictionary configuration."
      backup
    rescue RimeDeployError, SystemCallError => error
      puts "Restore stopped; earlier items may already be restored. Backup: #{backup}" if backup
      raise error
    end

    private

    def require_data_directory
      unless File.directory?(@path) && !File.symlink?(@path)
        raise RimeDeployError, "Rime data path must be a real directory: #{@path}"
      end
    end

    def require_restore_workspace
      temporary_database = File.join(@path, ".temp.userdb")
      if File.exist?(temporary_database) || File.symlink?(temporary_database)
        raise RimeDeployError, "Refusing native restore while #{temporary_database} exists; preserve it and resolve it manually."
      end
    end

    def validate_name(name)
      unless name.is_a?(String) && name.match?(/\A[a-zA-Z0-9_][a-zA-Z0-9_.-]*\z/)
        raise RimeDeployError, "Invalid user dictionary name."
      end
    end

    def validate_dictionary_name(name)
      validate_name(name)
      raise RimeDeployError, "Invalid user dictionary name: native Rime would truncate it." if name.include?(".userdb")
    end

    def validate_data_file(relative)
      valid = relative.is_a?(String) &&
        (relative.end_with?(".dict.yaml") || relative.match?(/\Acustom_phrase[^\/\\]*\.txt\z/))
      raise RimeDeployError, "Unsupported personal file in backup." unless valid
    end

    def checked_path(base, relative, file: false)
      unless relative.is_a?(String) && !relative.match?(/[\\:\x00-\x1f]/) &&
          relative.split("/", -1).all? { |part| !part.empty? && !part.start_with?(".") }
        raise RimeDeployError, "Unsafe path in personal data."
      end
      raise RimeDeployError, "Symlink directory is not supported: #{base}" if File.symlink?(base)
      path = base
      parts = relative.split("/")
      parts.each_with_index do |part, index|
        path = File.join(path, part)
        raise RimeDeployError, "Refusing symlink: #{path}" if File.symlink?(path)
        if index < parts.length - 1 && File.exist?(path) && !File.directory?(path)
          raise RimeDeployError, "Not a directory: #{path}"
        end
      end
      raise RimeDeployError, "Missing personal data file: #{path}" if file && !File.file?(path)
      path
    end

    def personal_files
      phrases = Dir.glob("custom_phrase*.txt", base: @path)
      dictionaries = Dir.glob("**/*.dict.yaml", base: @path)
      if File.exist?(File.join(@path, ".git"))
        tracked = git_output("ls-files", "-z").split("\0")
        changed = git_output("diff", "--name-only", "-z", "HEAD", "--").split("\0")
        dictionaries.select! { |relative| !tracked.include?(relative) || changed.include?(relative) }
      end
      (phrases + dictionaries).sort
    end

    def git_output(*arguments)
      output, error, status = Open3.capture3("git", "-C", @path, *arguments)
      raise RimeDeployError, "Cannot identify personal dictionary files: #{error}" unless status.success?
      output
    end

    def sync_settings
      installation = checked_path(@path, "installation.yaml", file: true)
      config = YAML.safe_load(File.read(installation))
      unless config.is_a?(Hash) && config["installation_id"].is_a?(String)
        raise RimeDeployError, "Deploy Rime first to generate this machine's installation_id."
      end
      id = config.fetch("installation_id")
      validate_name(id)
      sync = config.fetch("sync_dir", "sync")
      raise RimeDeployError, "Invalid Rime sync_dir." unless sync.is_a?(String) && !sync.empty?
      [File.expand_path(sync, @path), id]
    rescue Psych::Exception => error
      raise RimeDeployError, "Cannot read Rime installation settings: #{error.message}"
    end

    def dict_manager
      configured = @manager || ENV["RIME_DICT_MANAGER"]
      candidates = if configured
        [File.expand_path(configured)]
      else
        [
          "/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_dict_manager",
          File.expand_path("~/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_dict_manager")
        ] + ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).flat_map do |directory|
          ["rime_dict_manager", "rime_dict_manager.exe"].map { |name| File.join(directory, name) }
        end
      end
      @manager = candidates.map { |candidate| File.expand_path(candidate) }.find do |candidate|
        File.file?(candidate) && File.executable?(candidate)
      end
      unless @manager
        raise RimeDeployError, "rime_dict_manager is required. Install the Rime dictionary tools or set RIME_DICT_MANAGER to its executable path."
      end
      @manager
    end

    def run_manager(*arguments)
      _, error, status = Open3.capture3({"GLOG_logtostderr" => "1"}, dict_manager, *arguments, chdir: @path)
      unless status.success?
        raise RimeDeployError, "Rime dictionary operation failed. Quit the input method completely and retry; a locked database cannot be backed up or restored.\n#{error.lines.last(4).join}"
      end
    end

    def backup_dictionary(name, snapshot, destination)
      if File.exist?(snapshot) && !File.file?(snapshot)
        raise RimeDeployError, "Snapshot path is not a regular file: #{snapshot}"
      end
      FileUtils.mkdir_p(File.dirname(snapshot))
      holding = Dir.mktmpdir(".rime-snapshot-", File.dirname(snapshot))
      previous = File.join(holding, "previous.userdb.txt")
      started = false
      complete = false
      begin
        File.rename(snapshot, previous) if File.exist?(snapshot)
        started = true
        run_manager("--backup", name)
        validate_snapshot(snapshot, name)
        FileUtils.cp(snapshot, destination)
        complete = true
      ensure
        if started && !complete
          if File.exist?(previous)
            File.rename(previous, snapshot)
          elsif File.file?(snapshot) || File.symlink?(snapshot)
            File.unlink(snapshot)
          end
        end
        FileUtils.remove_entry(holding) if complete || !File.exist?(previous)
      end
    end

    def validate_snapshot(path, name)
      raise RimeDeployError, "Missing dictionary snapshot: #{path}" unless File.file?(path) && !File.symlink?(path)
      names = []
      types = []
      File.foreach(path, encoding: "UTF-8") do |line|
        unless line.valid_encoding? && line.end_with?("\n")
          raise RimeDeployError, "Incomplete or malformed dictionary snapshot: #{path}"
        end
        names << line.delete_prefix("#@/db_name\t").chomp if line.start_with?("#@/db_name\t")
        types << line.delete_prefix("#@/db_type\t").chomp if line.start_with?("#@/db_type\t")
        next if line.start_with?("#") || line.strip.empty?
        fields = line.chomp.split("\t", -1)
        unless fields.length == 3 && fields.none?(&:empty?) &&
            fields.last.match?(/\Ac=-?\d+ d=[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)? t=\d+\z/)
          raise RimeDeployError, "Incomplete or malformed dictionary snapshot: #{path}"
        end
      end
      unless names == [name] && types == ["userdb"]
        raise RimeDeployError, "Snapshot metadata does not match dictionary #{name}."
      end
    end

    def load_bundle(bundle)
      path = checked_path(bundle, "manifest.json", file: true)
      manifest = JSON.parse(File.read(path))
      unless manifest.is_a?(Hash) && manifest["version"] == 1 &&
          manifest["dictionaries"].is_a?(Array) && manifest["files"].is_a?(Array)
        raise RimeDeployError, "Unsupported personal data backup format."
      end
      %w[dictionaries files].each do |key|
        raise RimeDeployError, "Duplicate entries in personal data backup." unless manifest[key].uniq == manifest[key]
      end
      manifest["dictionaries"].each do |name|
        validate_dictionary_name(name)
        snapshot = checked_path(bundle, "dictionaries/#{name}.userdb.txt", file: true)
        validate_snapshot(snapshot, name)
      end
      manifest["files"].each do |relative|
        validate_data_file(relative)
        checked_path(bundle, "files/#{relative}", file: true)
      end
      manifest
    rescue JSON::ParserError => error
      raise RimeDeployError, "Invalid personal data manifest: #{error.message}"
    end
  end

  class ExportPersonalDataJob < Job
    def call
      puts "Quit Rime completely before exporting. Native snapshots also update Rime's configured sync folder."
      puts "Personal data stays in this project's ignored personal-data directory; do not publish it accidentally."
      PersonalData.new.export
      :next
    end
  end

  class RestorePersonalDataJob < Job
    def call
      data = PersonalData.new
      bundles = data.bundles
      raise RimeDeployError, "No backups found. Copy an exported bundle into this project's personal-data directory first." if bundles.empty?
      items = [["Cancel", -> { nil }]] + bundles.map { |bundle| [File.basename(bundle), -> { bundle }] }
      bundle = ChooseSession.new(items, default: 1).call
      return :next unless bundle
      puts "Quit Rime completely. Learning data will be merged; phrase and dictionary files will be replaced after backup."
      confirmed = ChooseSession.new([
        ["Cancel", -> { false }],
        ["Back up this machine and restore the selected bundle", -> { true }]
      ], default: 1).call
      data.restore(bundle) if confirmed
      :next
    end
  end
end
