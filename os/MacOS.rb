module RimeDeploy
  class MacOSJobGroup < JobGroup
    InstallCmd = "brew install --cask squirrel"
    Store.config_path = "~/Library/Rime"

    class InstallRimeJob < Job
      def call
        puts intro
        raise RimeDeployError, "Squirrel installation failed." unless system(InstallCmd)
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
        puts "Enjoy~ 🍻"
        puts "more info:".yellow
        puts "Config path: #{Store.config_path}/"
        return :next
      end
    end

    self.jobs = [
      InstallRimeJob,
      BackupRimeConfigJob,
      CloneConfigJob,
      CopyCustomConfigJob
    ]
    self.after_jobs = [FinishedJob]
    self.upgrade_jobs = [
      Upgrade::UpgradeRimeAutoDeployJob,
      Upgrade::UpgradeRimeConfigJob
    ]
  end
end
