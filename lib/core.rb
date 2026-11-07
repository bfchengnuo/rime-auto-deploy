require "fileutils"
require "tmpdir"
require "tempfile"

module FontStylePatch
  RESET_COLOR = "\e[0m" #重置所有颜色和样式
  COLORS = {
    black: "\e[30m", #黑色文本
    red: "\e[31m", #红色文本
    green: "\e[32m", #绿色文本
    yellow: "\e[33m", #黄色文本
    blue: "\e[34m", #蓝色文本
    carmine: "\e[35m", #洋红色文本
    cyan: "\e[36m", #青色文本
    white: "\e[37m" #白色文本
  }
  COLORS.keys.each do |color_name|
    define_method(color_name) do
      return "#{COLORS[color_name]}#{self}#{RESET_COLOR}"
    end
  end
end

module StringPatch
  def nature_case
    self.gsub(/(.)([A-Z])/, '\1 \2').downcase.capitalize
  end
end

class String
  include FontStylePatch
  include StringPatch
end

module RimeDeploy
  class RimeDeployError < StandardError
  end

  class ChooseSession
    def initialize(items, default: nil)
      @items = items #[[intro, method]] auto index
      @default = default
    end

    def call
      message = nil
      choose = nil
      while true
        puts @title
        puts "Choose mode:"
        @items.each_with_index do |item, index|
          puts "[#{index + 1}] " + item[0]
        end
        puts "Tips: input the index. e.g: 1; Ctrl-C exit."
        puts "Enter selects #{@default}." if @default
        puts "Message: #{message}".red if message
        print ">>".green
        choose_mode = $stdin.gets
        raise RimeDeployError, "Input ended without a selection." unless choose_mode
        choose_index = choose_mode.strip
        choose_index = @default.to_s if choose_index.empty? && @default
        if choose_index =~ /\A[1-9]\d*\z/ && choose_index.to_i <= @items.length
          choose = @items[choose_index.to_i - 1]
          break
        else
          message = "Wrong Index, try again."
        end
      end

      choose[1].call
    end
  end

  class Store
    @config_path = nil

    def self.config_path=(value)
      @config_path = value
    end

    def self.config_path
      @config_path
    end
  end

  class Job
    attr_accessor :status, :intro
    def initialize
      @status = :waiting # :waiting, :processing, :done, :fail
      klass_name = self.class.to_s.split("::").last.sub(/Job$/, "")
      @intro = klass_name.nature_case
    end

    def call
    end

    def rollback
    end

    def backup_rime_config
      path = File.expand_path(Store.config_path)
      unless File.exist?(path)
        puts "No existing Rime directory to back up."
        return :next
      end
      unless File.directory?(path) && !File.symlink?(path)
        raise RimeDeployError, "Rime path must be a real directory: #{path}"
      end
      backup = "#{path}.#{Time.now.strftime('%Y%m%d-%H%M%S-%N')}.old"
      raise RimeDeployError, "Backup already exists: #{backup}" if File.exist?(backup)
      puts "Moving the entire Rime directory to #{backup}"
      puts "Old user dictionaries stay in this backup; a fresh clone does not restore them."
      File.rename(path, backup)
      :next
    end

    def clone_rime_config
      path = File.expand_path(Store.config_path)
      if File.exist?(path) || File.symlink?(path)
        raise RimeDeployError, "Rime path already exists. Use Upgrade mode instead: #{path}"
      end
      unless system("git", "clone", "--depth=1", Config::RIME_CONFIG_REPO, path)
        raise RimeDeployError, "Cloning failed. Existing backups have not been changed."
      end
      :next
    end

    def copy_custom_config
      path = File.expand_path(Store.config_path)
      raise RimeDeployError, "Rime directory does not exist: #{path}" unless File.directory?(path)

      template_dir = File.expand_path("../custom", __dir__)
      templates = Dir.glob("*.custom.yaml", base: template_dir).sort
      raise RimeDeployError, "No custom templates found: #{template_dir}" if templates.empty?
      backup = nil
      templates.each do |name|
        source = File.join(template_dir, name)
        target = File.join(path, name)
        if File.symlink?(target) || (File.exist?(target) && !File.file?(target))
          raise RimeDeployError, "Refusing to overwrite a non-regular file: #{target}"
        end
        if File.exist?(target)
          next if FileUtils.compare_file(source, target)

          backup ||= Dir.mktmpdir("#{File.basename(path)}.custom-backup-", File.dirname(path))
          FileUtils.cp(target, File.join(backup, name), preserve: true)
          puts "Backup: #{File.join(backup, name)}"
        end
        Tempfile.create([".rime-custom-", ".yaml"], path) do |file|
          file.close
          FileUtils.cp(source, file.path)
          File.rename(file.path, target)
        end
        puts "Applied #{target}"
      end
      puts "Only *.custom.yaml templates are applied; dictionaries and installation.yaml are untouched."
      :next
    end

    def upgrade_repository(path)
      unless system("git", "-C", path, "diff", "--quiet", "HEAD", "--")
        raise RimeDeployError, "Tracked files have local changes, or Git could not check them. Back up and resolve them before upgrading."
      end
      unless system("git", "-C", path, "fetch")
        raise RimeDeployError, "Git fetch failed. Working files have not been changed."
      end
      unless system("git", "-C", path, "merge", "--ff-only", "--no-overwrite-ignore", "@{upstream}")
        raise RimeDeployError, "Git upgrade refused or failed. No reset, cleanup or reinstall was attempted."
      end
      :next
    end
  end

  class JobGroup
    @jobs = []
    @after_jobs = []
    @before_jobs = []

    def self.jobs
      @jobs
    end
    def self.jobs=(value)
      @jobs = value
    end

    def self.after_jobs
      @after_jobs
    end
    def self.after_jobs=(value)
      @after_jobs = value
    end

    def self.before_jobs
      @before_jobs
    end

    def self.before_jobs=(value)
      @before_jobs = value
    end

    def self.upgrade_jobs
      @upgrade_jobs
    end

    def self.upgrade_jobs=(value)
      @upgrade_jobs = value
    end

    def add_jobs_to_queue(jobs = nil)
      jobs.each { |job| @queue << job.new } if jobs
    end

    def add_before_jobs_to_queue(jobs = nil)
      jobs.each { |job| @before_jobs << job.new } if jobs
    end

    def add_after_jobs_to_queue(jobs = nil)
      jobs.each { |job| @after_jobs << job.new }
    end

    def initialize()
      @title = "=== Rime Deploy ====".green
      @before_jobs = []
      @queue = []
      @after_jobs = []
      @current_index = 0

      add_before_jobs_to_queue(self.class.before_jobs)
      add_after_jobs_to_queue(self.class.after_jobs)
    end

    def clear_screen
      system("clear")
    end

    def print_progress
      clear_screen
      puts @title
      @queue.each_with_index do |job, index|
        job_id = "[%02d]" % (index + 1)
        job_intro = job.intro.to_s.ljust(20).green
        job_status = job.status
        case job_status
        when :waiting
          job_status = job_status.to_s.white
        when :processing
          job_status = job_status.to_s.yellow
        when :done
          job_status = job_status.to_s.green
        end
        job_status = job_status.rjust(15)
        puts "#{job_id} #{job_intro}\t#{job_status}"
      end

      if @current_index < @queue.length
        puts "Total: #{@queue.length}".ljust(10)
        puts "Detail " + "-" * 20
      end
    end

    def run_job_with_info_wrapper(current_job)
      loop do
        current_job.status = :processing
        print_progress
        begin
          result = current_job.call
          unless result == :next
            current_job.rollback
            raise RimeDeployError, "#{current_job.intro} failed."
          end
          current_job.status = :done
          @current_index += 1
          print_progress
          return
        rescue RimeDeployError, SystemCallError => error
          current_job.status = :fail
          puts error.message.red
          what_next
        end
      end
    end

    def guidance
      puts @title
      puts "welcome to use Rime installer."
      ChooseSession.new(
        [
          [
            "Auto mode: Suitable for first-time operation.".green,
            -> { run_jobs_auto }
          ],
          [
            "Handle mode: Decide to execute on your own.".green,
            -> { run_jobs_handle }
          ],
          [
            "Upgrade mode: Suitable for upgrade exist Rime".green,
            -> { run_jobs_upgrade }
          ]
        ]
      ).call
    end

    def run_jobs_handle
      add_jobs_to_queue(self.class.jobs)
      add_jobs_to_queue([ExportPersonalDataJob, RestorePersonalDataJob])
      halt_flag =
        catch :halt do
          clear_screen
          puts "[Handle Mode]".yellow
          handle_jobs = []
          @queue.each_with_index do |job, index|
            job_intro = job.intro.to_s.ljust(20).green
            handle_jobs.push(
              ["#{job_intro}", -> { run_job_with_info_wrapper(job) }]
            )
          end
          begin
            ChooseSession.new(handle_jobs).call
          rescue RimeDeployError
            what_next
          end
        end
      reset_queue
      run_jobs_handle if halt_flag == :handle_mode
    end

    def run_jobs_auto
      add_jobs_to_queue(self.class.jobs)
      clear_screen
      puts "[Auto Mode]".green
      print_progress
      halt_flag =
        catch :halt do
          while @current_index < @queue.length
            run_job_with_info_wrapper(@queue[@current_index])
          end
        end
      reset_queue
      run_jobs_handle if halt_flag == :handle_mode
    end

    def run_jobs_upgrade
      add_jobs_to_queue(self.class.upgrade_jobs)
      halt_flag =
        catch :halt do
          clear_screen
          puts "[Upgrade Mode]".yellow
          upgrade_jobs = []
          @queue.each_with_index do |job, index|
            job_intro = job.intro.to_s.ljust(20).green
            upgrade_jobs.push(
              ["#{job_intro}", -> { run_job_with_info_wrapper(job) }]
            )
          end
          begin
            ChooseSession.new(upgrade_jobs).call
          rescue RimeDeployError
            what_next
          end
        end
      reset_queue
      run_jobs_handle if halt_flag == :handle_mode
      run_jobs_upgrade if halt_flag == :run_jobs_upgrade
    end

    def reset_queue
      @queue = []
      @current_index = 0
    end

    def reset_status
      @queue.each { |q| q.status = :waiting }
    end

    def what_next
      puts ""
      puts "Raise an error. Next, you want to...".red
      ChooseSession.new(
        [
          ["Retry", -> {}],
          ["Change to: Handle mode", -> { throw :halt, :handle_mode }],
          ["Exit", -> { exit 1 }]
        ]
      ).call
    end

    def call
      @before_jobs.length > 0 && @before_jobs.each { |job| job.call }
      guidance
      @after_jobs.length > 0 && @after_jobs.each { |job| job.call }
    end
  end
end
