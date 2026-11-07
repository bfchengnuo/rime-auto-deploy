module RimeDeploy
  class LinuxDistroJobGroup < JobGroup
    ConfigPathIbus = "~/.config/ibus/rime"
    ConfigPathFcitx = "~/.config/fcitx/rime"
    ConfigPathFcitx5 = "~/.local/share/fcitx5/rime"

    class CheckInstallRimeJob < Job
      def call
        puts "==== Rime auto deploy ====".green
        puts "Before Check Rime Installed Staus".yellow
        tips = <<-TIP
Different Linux has it's own package manager. So make sure you had installed Rime before.

For Fcitx5, install fcitx5-rime.
For Fcitx, install fcitx-rime.
For IBus, install ibus-rime.

more:
https://wiki.archlinux.org/title/Rime
        TIP
        puts tips
        puts ""
        puts "Then choose what your had installed."
        ChooseSession.new(
          [
            [
              "ibus-rime",
              -> { Store.config_path = LinuxDistroJobGroup::ConfigPathIbus }
            ],
            [
              "fcitx-rime",
              -> { Store.config_path = LinuxDistroJobGroup::ConfigPathFcitx }
            ],
            [
              "fcitx5-rime",
              -> { Store.config_path = LinuxDistroJobGroup::ConfigPathFcitx5 }
            ],
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
        puts "Enjoy~ 🍻"
        puts "more info:".yellow
        puts "Config path: #{Store.config_path}/"
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
