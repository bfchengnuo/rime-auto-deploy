require "minitest/autorun"
require "stringio"
require "open3"
require "yaml"
require_relative "../lib/core"
require_relative "../lib/config"
require_relative "../share/upgrade"
require_relative "../share/personal_data"
require_relative "../os/MacOS"
require_relative "../os/LinuxDistro"

appdata = ENV["APPDATA"]
ENV["APPDATA"] ||= Dir.tmpdir
require_relative "../os/Windows"
ENV["APPDATA"] = appdata

class DeployTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PLATFORMS = [RimeDeploy::MacOSJobGroup, RimeDeploy::LinuxDistroJobGroup, RimeDeploy::WindowsJobGroup]

  def setup
    @root = Dir.mktmpdir("rime-deploy-test-")
    @path = File.join(@root, "Rime with spaces")
    FileUtils.mkdir_p(@path)
    @original_path = RimeDeploy::Store.config_path
    RimeDeploy::Store.config_path = @path
    @job = RimeDeploy::Job.new
  end

  def teardown
    RimeDeploy::Store.config_path = @original_path
    FileUtils.remove_entry(@root)
  end

  def write(relative, content)
    path = File.join(@path, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def snapshot(path = @path)
    Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).select { |file| File.file?(file) }.sort.map do |file|
      [file.delete_prefix(path + File::SEPARATOR), File.binread(file)]
    end.to_h
  end

  def with_input(input)
    previous = $stdin
    $stdin = StringIO.new(input)
    capture_io { yield }
  ensure
    $stdin = previous
  end

  def seed_templates
    Dir.glob(File.join(ROOT, "custom", "*.custom.yaml")).each do |file|
      FileUtils.cp(file, @path)
    end
  end

  def git(*args)
    output, error, status = Open3.capture3("git", *args)
    assert status.success?, error
    output.strip
  end

  def prepare_upgrade
    revisions = git("-C", ROOT, "rev-list", "--max-count=2", "HEAD").lines.map(&:strip)
    assert_equal 2, revisions.length
    @latest, previous = revisions
    remote = File.join(@root, "remote.git")
    git("clone", "--bare", "--no-hardlinks", ROOT, remote)
    branch = git("-C", remote, "symbolic-ref", "HEAD")
    git("-C", remote, "update-ref", branch, previous)
    checkout = File.join(@root, "checkout with spaces")
    git("clone", remote, checkout)
    git("-C", remote, "update-ref", branch, @latest)
    @path = checkout
    RimeDeploy::Store.config_path = @path
    write(".git/info/exclude", "*.userdb/\n*.custom.yaml\ninstallation.yaml\nuser.yaml\n")
  end

  def test_fuzzy_initials_removed_but_abbreviations_and_typo_correction_remain
    config = YAML.load_file(File.join(ROOT, "custom", "rime_ice.custom.yaml"))
    rules = config.fetch("patch").fetch("speller").fetch("algebra")
    ["derive/^([zcs])h/$1/", "derive/^([zcs])([^h])/$1h$2/", "derive/^l/n/", "derive/^n/l/", "derive/^f/h/", "derive/^h/f/"].each do |rule|
      refute_includes rules, rule
    end
    assert_includes rules, "abbrev/^([a-z]).+$/$1/"
    assert_includes rules, "derive/^([wghk])ai$/$1ia/"
  end

  def test_copy_preserves_dictionaries_machine_metadata_and_unrelated_configuration
    write("rime_ice.userdb/000001.log", "\x00\xfflearned words".b)
    write("cn_dicts/personal.dict.yaml", "personal words")
    write("custom_phrase.txt", "my phrases")
    write("installation.yaml", "installation_id: my-device\nsync_dir: my-sync\n")
    write("user.yaml", "my preferences")
    write("personal.custom.yaml", "my own schema patch")
    before = snapshot
    with_input("") { assert_equal :next, @job.copy_custom_config }
    before.each { |file, content| assert_equal content, File.binread(File.join(@path, file)) }
    assert File.file?(File.join(@path, "rime_ice.custom.yaml"))
    assert_empty Dir.glob(File.join(@root, "*.custom-backup-*"))
  end

  def test_new_install_does_not_copy_machine_identity_template
    with_input("") { @job.copy_custom_config }
    refute File.exist?(File.join(@path, "installation.yaml"))
  end

  def test_copy_applies_all_changed_templates_without_confirmation
    seed_templates
    Dir.children(@path).each { |name| write(name, "old #{name}") }
    before = snapshot
    with_input("") { @job.copy_custom_config }
    backups = Dir.glob(File.join(@root, "*.custom-backup-*"))
    assert_equal 1, backups.length
    assert_equal before, snapshot(backups.first)
    Dir.children(@path).each do |name|
      assert_equal File.binread(File.join(ROOT, "custom", name)), File.binread(File.join(@path, name))
    end
  end

  def test_copy_backs_up_changed_files_and_is_idempotent
    seed_templates
    original = "patch:\n  personal: true\n"
    write("rime_ice.custom.yaml", original)
    write("installation.yaml", "my-device")
    with_input("") { @job.copy_custom_config }
    backups = Dir.glob(File.join(@root, "*.custom-backup-*"))
    assert_equal 1, backups.length
    assert_equal({"rime_ice.custom.yaml" => original}, snapshot(backups.first))
    assert_equal File.binread(File.join(ROOT, "custom/rime_ice.custom.yaml")), File.binread(File.join(@path, "rime_ice.custom.yaml"))
    assert_equal "my-device", File.binread(File.join(@path, "installation.yaml"))
    with_input("") { @job.copy_custom_config }
    assert_equal backups, Dir.glob(File.join(@root, "*.custom-backup-*"))
  end

  def test_identical_templates_do_not_require_input_or_create_backups
    seed_templates
    before = snapshot
    with_input("") { assert_equal :next, @job.copy_custom_config }
    assert_equal before, snapshot
    assert_empty Dir.glob(File.join(@root, "*.custom-backup-*"))
  end

  def test_copy_refuses_missing_templates
    Dir.stub(:glob, []) do
      assert_raises(RimeDeploy::RimeDeployError) { @job.copy_custom_config }
    end
    assert_empty snapshot
  end

  def test_failed_template_write_leaves_original_file_intact
    seed_templates
    write("rime_ice.custom.yaml", "my original settings")
    original_copy = FileUtils.method(:cp)
    copy = lambda do |source, target, **options|
      raise Errno::ENOSPC, "disk full" if source.start_with?(File.join(ROOT, "custom"))
      original_copy.call(source, target, **options)
    end
    FileUtils.stub(:cp, copy) do
      with_input("2\n") { assert_raises(Errno::ENOSPC) { @job.copy_custom_config } }
    end
    assert_equal "my original settings", File.read(File.join(@path, "rime_ice.custom.yaml"))
    assert_empty Dir.glob(File.join(@path, ".rime-custom-*"))
    backups = Dir.glob(File.join(@root, "*.custom-backup-*"))
    assert_equal 1, backups.length
    assert_equal "my original settings", File.read(File.join(backups.first, "rime_ice.custom.yaml"))
  end

  def test_copy_works_when_project_path_contains_glob_characters
    project = File.join(@root, "project [test]")
    FileUtils.mkdir_p(File.join(project, "lib"))
    FileUtils.cp(File.join(ROOT, "lib/core.rb"), File.join(project, "lib/core.rb"))
    FileUtils.cp_r(File.join(ROOT, "custom"), project)
    code = 'RimeDeploy::Store.config_path = ARGV.fetch(0); RimeDeploy::Job.new.copy_custom_config'
    _, error, status = Open3.capture3(RbConfig.ruby, "-r", File.join(project, "lib/core.rb"), "-e", code, @path, chdir: @root)
    assert status.success?, error
    assert File.exist?(File.join(@path, "rime_ice.custom.yaml"))
    refute File.exist?(File.join(@path, "installation.yaml"))
  end

  def test_copy_refuses_missing_directory
    RimeDeploy::Store.config_path = File.join(@root, "missing")
    assert_raises(RimeDeploy::RimeDeployError) { @job.copy_custom_config }
    refute File.exist?(RimeDeploy::Store.config_path)
  end

  def test_copy_refuses_symlink_target
    seed_templates
    target = File.join(@path, "rime_ice.custom.yaml")
    File.unlink(target)
    outside = File.join(@root, "external.yaml")
    File.write(outside, "external")
    File.symlink(outside, target)
    with_input("2\n") { assert_raises(RimeDeploy::RimeDeployError) { @job.copy_custom_config } }
    assert_equal "external", File.read(outside)
  end

  def test_backup_moves_entire_tree_including_hidden_files_and_user_dictionary
    write(".git/config", "hidden metadata")
    write("rime_ice.userdb/000001.ldb", "\x00\xffdatabase".b)
    write("cn_dicts/personal.dict.yaml", "personal words")
    write("custom_phrase.txt", "my phrases")
    before = snapshot
    capture_io { assert_equal :next, @job.backup_rime_config }
    refute File.exist?(@path)
    backups = Dir.glob("#{@path}.*.old")
    assert_equal 1, backups.length
    assert_equal before, snapshot(backups.first)
  end

  def test_backup_skips_absent_directory
    RimeDeploy::Store.config_path = File.join(@root, "missing")
    capture_io { assert_equal :next, @job.backup_rime_config }
    assert_empty Dir.glob(File.join(@root, "*.old"))
  end

  def test_clone_refuses_to_overwrite_existing_data
    write("rime_ice.userdb/data", "learned")
    before = snapshot
    @job.stub(:system, ->(*) { flunk "Git must not run" }) do
      assert_raises(RimeDeploy::RimeDeployError) { @job.clone_rime_config }
    end
    assert_equal before, snapshot
  end

  def test_clone_reports_command_failure_and_uses_separate_arguments
    RimeDeploy::Store.config_path = File.join(@root, "new Rime")
    calls = []
    @job.stub(:system, ->(*args) { calls << args; false }) do
      assert_raises(RimeDeploy::RimeDeployError) { @job.clone_rime_config }
    end
    assert_equal [["git", "clone", "--depth=1", RimeDeploy::Config::RIME_CONFIG_REPO, RimeDeploy::Store.config_path]], calls
  end

  def test_fast_forward_upgrade_preserves_personal_files
    prepare_upgrade
    personal = {
      "rime_ice.userdb/data" => "learned words",
      "rime_ice.custom.yaml" => "my patch",
      "installation.yaml" => "my-device",
      "user.yaml" => "my preferences",
      "custom_phrase.txt" => "my phrases",
      "cn_dicts/personal.dict.yaml" => "my dictionary"
    }
    personal.each { |file, content| write(file, content) }
    capture_subprocess_io { assert_equal :next, RimeDeploy::Upgrade::UpgradeRimeConfigJob.new.call }
    assert_equal @latest, git("-C", @path, "rev-parse", "HEAD")
    personal.each { |file, content| assert_equal content, File.binread(File.join(@path, file)) }
  end

  def test_upgrade_refuses_tracked_local_edits
    prepare_upgrade
    previous = git("-C", @path, "rev-parse", "HEAD")
    write("README.md", "my tracked changes")
    capture_subprocess_io do
      assert_raises(RimeDeploy::RimeDeployError) { @job.upgrade_repository(@path) }
    end
    assert_equal previous, git("-C", @path, "rev-parse", "HEAD")
    assert_equal "my tracked changes", File.read(File.join(@path, "README.md"))
  end

  def test_upgrade_refuses_staged_local_edits
    prepare_upgrade
    write("README.md", "my staged changes")
    git("-C", @path, "add", "README.md")
    capture_subprocess_io do
      assert_raises(RimeDeploy::RimeDeployError) { @job.upgrade_repository(@path) }
    end
    assert_equal "my staged changes", File.read(File.join(@path, "README.md"))
  end

  def test_upgrade_reports_fetch_failure_without_cleanup
    calls = []
    @job.stub(:system, ->(*args) { calls << args; calls.length == 1 }) do
      assert_raises(RimeDeploy::RimeDeployError) { @job.upgrade_repository(@path) }
    end
    assert_equal [["git", "-C", @path, "diff", "--quiet", "HEAD", "--"], ["git", "-C", @path, "fetch"]], calls
  end

  def test_upgrade_protects_ignored_files_and_reports_merge_failure
    calls = []
    @job.stub(:system, ->(*args) { calls << args; calls.length < 3 }) do
      assert_raises(RimeDeploy::RimeDeployError) { @job.upgrade_repository(@path) }
    end
    assert_equal ["git", "-C", @path, "merge", "--ff-only", "--no-overwrite-ignore", "@{upstream}"], calls.last
    assert_equal 3, calls.length
  end

  def test_upgrade_of_non_git_directory_preserves_data
    write("personal.dict.yaml", "my words")
    before = snapshot
    capture_io do
      assert_raises(RimeDeploy::RimeDeployError) { RimeDeploy::Upgrade::UpgradeRimeConfigJob.new.call }
    end
    assert_equal before, snapshot
  end

  def test_installer_step04_uses_isolated_home_and_preserves_personal_data
    home = File.join(@root, "home")
    @path = File.join(home, "Library", "Rime")
    FileUtils.mkdir_p(@path)
    seed_templates
    write("rime_ice.custom.yaml", "my old patch")
    write("installation.yaml", "installation_id: isolated-device\n")
    write("rime_ice.userdb/data", "learned words")
    write("custom_phrase.txt", "my phrases")
    output, error, status = Open3.capture3(
      {"HOME" => home, "TERM" => "xterm"}, RbConfig.ruby, File.join(ROOT, "installer.rb"),
      stdin_data: "2\n4\n", chdir: @root
    )
    assert status.success?, error
    assert_includes output, "Applied"
    assert_equal File.binread(File.join(ROOT, "custom/rime_ice.custom.yaml")), File.binread(File.join(@path, "rime_ice.custom.yaml"))
    assert_equal "installation_id: isolated-device\n", File.read(File.join(@path, "installation.yaml"))
    assert_equal "learned words", File.read(File.join(@path, "rime_ice.userdb/data"))
    assert_equal "my phrases", File.read(File.join(@path, "custom_phrase.txt"))
    backups = Dir.glob(File.join(home, "Library", "Rime.custom-backup-*"))
    assert_equal 1, backups.length
    assert_equal "my old patch", File.read(File.join(backups.first, "rime_ice.custom.yaml"))
  end

  def test_manual_menu_exposes_export_and_restore_without_adding_them_to_auto_mode
    [RimeDeploy::ExportPersonalDataJob, RimeDeploy::RestorePersonalDataJob].each_with_index do |expected, index|
      group = RimeDeploy::MacOSJobGroup.new
      selected = nil
      group.stub(:clear_screen, nil) do
        group.stub(:run_job_with_info_wrapper, ->(job) { selected = job.class }) do
          with_input("#{index + 5}\n") { group.run_jobs_handle }
        end
      end
      assert_equal expected, selected
      refute_includes RimeDeploy::MacOSJobGroup.jobs, expected
    end
    assert_equal 4, RimeDeploy::MacOSJobGroup.jobs.length
  end

  def test_personal_file_detection_excludes_unmodified_public_dictionaries
    write("cn_dicts/base.dict.yaml", "public")
    write("cn_dicts/modified.dict.yaml", "modified")
    write("cn_dicts/mine.dict.yaml", "mine")
    write("custom_phrase.txt", "phrases")
    FileUtils.mkdir_p(File.join(@path, ".git"))
    data = RimeDeploy::PersonalData.new(@path, backup_root: File.join(@root, "exports"))
    output = lambda do |*arguments|
      arguments.first == "ls-files" ? "cn_dicts/base.dict.yaml\0cn_dicts/modified.dict.yaml\0" : "cn_dicts/modified.dict.yaml\0"
    end
    data.stub(:git_output, output) do
      assert_equal ["cn_dicts/mine.dict.yaml", "cn_dicts/modified.dict.yaml", "custom_phrase.txt"], data.send(:personal_files)
    end
  end

  def test_restore_menu_defaults_to_cancel
    data = RimeDeploy::PersonalData.new(@path, backup_root: File.join(@root, "exports"))
    data.stub(:bundles, [File.join(@root, "export-example")]) do
      data.stub(:restore, ->(*) { flunk "Canceled restore must not run" }) do
        RimeDeploy::PersonalData.stub(:new, data) do
          with_input("\n") { assert_equal :next, RimeDeploy::RestorePersonalDataJob.new.call }
          with_input("2\n\n") { assert_equal :next, RimeDeploy::RestorePersonalDataJob.new.call }
        end
      end
    end
  end

  def test_installer_exports_and_restores_personal_files_in_isolation
    project = File.join(@root, "portable project")
    home = File.join(@root, "isolated home")
    FileUtils.mkdir_p(project)
    %w[installer.rb lib os share custom].each { |entry| FileUtils.cp_r(File.join(ROOT, entry), project) }
    @path = File.join(home, "Library", "Rime")
    write("custom_phrase.txt", "portable phrases")
    write("cn_dicts/mine.dict.yaml", "portable dictionary")
    write("installation.yaml", "installation_id: isolated-machine\n")
    command = [{"HOME" => home, "TERM" => "xterm"}, RbConfig.ruby, File.join(project, "installer.rb")]
    _, error, status = Open3.capture3(*command, stdin_data: "2\n5\n", chdir: @root)
    assert status.success?, error
    exports = Dir.glob(File.join(project, "personal-data", "export-*"))
    assert_equal 1, exports.length
    manifest = JSON.parse(File.read(File.join(exports.first, "manifest.json")))
    assert_equal ["cn_dicts/mine.dict.yaml", "custom_phrase.txt"], manifest.fetch("files")
    refute_includes manifest.fetch("files"), "installation.yaml"
    write("custom_phrase.txt", "target phrases")
    write("cn_dicts/mine.dict.yaml", "target dictionary")
    _, error, status = Open3.capture3(*command, stdin_data: "2\n6\n2\n2\n", chdir: @root)
    assert status.success?, error
    assert_equal "portable phrases", File.read(File.join(@path, "custom_phrase.txt"))
    assert_equal "portable dictionary", File.read(File.join(@path, "cn_dicts/mine.dict.yaml"))
    assert_equal "installation_id: isolated-machine\n", File.read(File.join(@path, "installation.yaml"))
    backups = Dir.glob(File.join(project, "personal-data", "before-restore-*"))
    assert_equal 1, backups.length
    assert_equal "target phrases", File.read(File.join(backups.first, "files", "custom_phrase.txt"))
    assert_equal "target dictionary", File.read(File.join(backups.first, "files", "cn_dicts/mine.dict.yaml"))
  end

  def test_platform_jobs_use_shared_protected_operations
    PLATFORMS.each do |platform|
      {BackupRimeConfigJob: :backup_rime_config, CloneConfigJob: :clone_rime_config, CopyCustomConfigJob: :copy_custom_config}.each do |name, method|
        job = platform.const_get(name).new
        called = false
        job.stub(method, -> { called = true; :next }) do
          capture_io { assert_equal :next, job.call }
        end
        assert called
      end
    end
  end

  def test_invalid_menu_input_does_not_select_destructive_option
    choices = [["keep", -> { :keep }], ["replace", -> { flunk "Invalid input selected replacement" }]]
    with_input("0\n-1\n2junk\n3\n1\n") do
      assert_equal :keep, RimeDeploy::ChooseSession.new(choices).call
    end
  end

  def test_upgrade_failure_can_switch_to_handle_mode
    group = RimeDeploy::MacOSJobGroup.new
    switched = false
    group.stub(:clear_screen, nil) do
      group.stub(:run_job_with_info_wrapper, ->(*) { throw :halt, :handle_mode }) do
        group.stub(:run_jobs_handle, -> { switched = true }) do
          with_input("2\n") { group.run_jobs_upgrade }
        end
      end
    end
    assert switched
  end

  def test_manual_retry_really_retries_failed_job
    group = RimeDeploy::MacOSJobGroup.new
    attempts = 0
    @job.stub(:call, -> { attempts += 1; raise RimeDeploy::RimeDeployError, "failure" if attempts == 1; :next }) do
      group.stub(:print_progress, nil) do
        with_input("1\n") { group.run_job_with_info_wrapper(@job) }
      end
    end
    assert_equal 2, attempts
    assert_equal :done, @job.status
    assert_equal 1, group.instance_variable_get(:@current_index)
  end

  def test_failed_job_exit_is_nonzero_and_not_marked_done
    group = RimeDeploy::MacOSJobGroup.new
    @job.stub(:call, -> { raise Errno::EACCES, "denied" }) do
      group.stub(:print_progress, nil) do
        with_input("3\n") do
          error = assert_raises(SystemExit) { group.run_job_with_info_wrapper(@job) }
          assert_equal 1, error.status
        end
      end
    end
    assert_equal :fail, @job.status
    assert_equal 0, group.instance_variable_get(:@current_index)
  end
end
