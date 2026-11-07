module RimeDeploy
  class WindowsJobGroup < JobGroup
    Store.config_path = ENV["APPDATA"] + '\\Rime'

    def clear_screen
      system("cls")
    end

    class CheckInstallRimeJob < Job
      def call
        puts "==== Rime auto deploy ====".green
        puts "Before Check Rime Installed Staus".yellow
        tips = <<-TIP
Windows system doesn't have it's own package manager, so make sure you had installed Rime before.

You can download Rime from: https://rime.im/download/

        TIP
        puts tips
        puts ""
        ChooseSession.new(
          [
            ["I have installed Rime. Let's go next.", -> {}],
            [
              "I'll quit first.After installed Rime by myself then run this program again.",
              -> { exit 0 }
            ]
          ]
        ).call
        sleep 1
        return :next
      end
    end

    class BackupRimeConfigJob < Job
      def call
        puts intro
        backup_rime_config
      end
    end

    class CloneConfigJob < Job
      def call
        puts intro
        clone_rime_config
      end
    end

    class CopyCustomConfigJob < Job
      def call
        puts intro
        copy_custom_config
      end
    end

    class FinishedJob < Job
      def call
        puts ""
        puts "Tips: When finished all jobs. You need to do follow:".yellow
        puts "Start the input method again if you stopped it."
        puts "After changing configuration or restoring personal data, click " +
               "DEPLOY".yellow + " in the Rime menu. Export alone needs no deployment."
        puts "Enjoy~"
        puts "more info:".yellow
        puts "Config path: #{Store.config_path}"
        return :next
      end
    end
    self.before_jobs = [CheckInstallRimeJob]
    self.jobs = [BackupRimeConfigJob, CloneConfigJob, CopyCustomConfigJob]
    self.after_jobs = [FinishedJob]
    self.upgrade_jobs = [
      Upgrade::UpgradeRimeAutoDeployJob,
      Upgrade::UpgradeRimeConfigJob
    ]
  end
end
