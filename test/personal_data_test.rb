# encoding: UTF-8
require "minitest/autorun"
require "minitest/mock"
require "timeout"
require_relative "../lib/core"
require_relative "../share/personal_data"

class PersonalDataTest < Minitest::Test
  MANAGER = "/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_dict_manager".freeze
  ERROR = RimeDeploy::RimeDeployError
  SOURCE_ENTRIES = [["测试假词甲", "ceshi jia", 7], ["测试假词乙", "ceshi yi", 11]].freeze
  TARGET_ENTRIES = [["测试目标假词", "mubiao jia", 13]].freeze

  def setup
    @tmp = Dir.mktmpdir("rime-personal-data-test-")
    @source = File.join(@tmp, "source")
    @target = File.join(@tmp, "target")
    @exports = File.join(@tmp, "exports")
    @backups = File.join(@tmp, "backups")
    write(@source, "installation.yaml", "installation_id: test-device\nsync_dir: sync\n")
    write(@target, "installation.yaml", "installation_id: test-target-device\nsync_dir: sync\n")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  def test_native_cross_device_restore_preserves_entries_frequency_and_snapshot_fields
    require_manager
    import_entries(@source, SOURCE_ENTRIES)
    import_entries(@target, TARGET_ENTRIES)
    write(@source, "custom_phrase.txt", "测试来源短语\tceshi\t5\n")
    write(@source, "personal/fixture.dict.yaml", dictionary("测试来源词典"))
    write(@target, "custom_phrase.txt", "测试原有短语\tyuan\t9\n")
    write(@target, "personal/fixture.dict.yaml", dictionary("测试原有词典"))
    original_installation = File.binread(File.join(@target, "installation.yaml"))
    original_phrase = File.binread(File.join(@target, "custom_phrase.txt"))
    original_dictionary = File.binread(File.join(@target, "personal/fixture.dict.yaml"))
    original_target_snapshot = native_snapshot(@target)

    bundle = quietly { source_service.export }
    source_snapshot = File.join(bundle, "dictionaries/fixture.userdb.txt")
    assert_equal File.binread(File.join(@source, "sync/test-device/fixture.userdb.txt")), File.binread(source_snapshot)
    assert_equal "test-device", metadata(source_snapshot).fetch("user_id")
    assert_equal ["fixture"], manifest(bundle).fetch("dictionaries")
    refute_includes manifest(bundle).fetch("files"), "installation.yaml"
    assert_equal SOURCE_ENTRIES.length, snapshot_rows(source_snapshot).length
    snapshot_rows(source_snapshot).each_value do |fields|
      assert_equal %w[c d t], fields.keys.sort
      assert_operator fields.fetch("c").to_i, :>, 0
    end

    expected_snapshot = directly_restored_snapshot(source_snapshot, TARGET_ENTRIES)
    backup = quietly { target_service.restore(bundle) }
    assert_match(/\Abefore-restore-/, File.basename(backup))
    assert_includes target_service.bundles, backup
    assert_equal original_installation, File.binread(File.join(@target, "installation.yaml"))
    assert_equal original_phrase, File.binread(File.join(backup, "files/custom_phrase.txt"))
    assert_equal original_dictionary, File.binread(File.join(backup, "files/personal/fixture.dict.yaml"))
    assert_equal original_target_snapshot, snapshot_rows(File.join(backup, "dictionaries/fixture.userdb.txt"))
    %w[custom_phrase.txt personal/fixture.dict.yaml].each do |relative|
      assert_equal File.binread(File.join(@source, relative)), File.binread(File.join(@target, relative))
    end
    assert_equal entry_map(SOURCE_ENTRIES + TARGET_ENTRIES), exported_entries(@target)

    restored_snapshot = native_snapshot(@target)
    assert_equal expected_snapshot, restored_snapshot
    assert_snapshot_fields_preserved(snapshot_rows(source_snapshot), restored_snapshot)
    original_target_snapshot.each { |key, fields| assert_equal fields, restored_snapshot.fetch(key) }
    assert_equal "test-target-device", metadata(File.join(@target, "sync/test-target-device/fixture.userdb.txt")).fetch("user_id")
    refute File.exist?(File.join(@target, "sync/test-device"))
  end

  def test_native_restore_on_a_new_machine_without_original_personal_data
    require_manager
    import_entries(@source, SOURCE_ENTRIES)
    write(@source, "custom_phrase.txt", "测试新机短语\txinji\t3\n")
    write(@source, "nested/fixture.dict.yaml", dictionary("测试新机词典"))
    bundle = quietly { source_service.export }
    original_installation = File.binread(File.join(@target, "installation.yaml"))
    assert_equal ["installation.yaml"], Dir.children(@target)
    source_snapshot = File.join(bundle, "dictionaries/fixture.userdb.txt")
    expected_snapshot = directly_restored_snapshot(source_snapshot, [])

    backup = quietly { target_service.restore(bundle) }
    assert_equal({"version" => 1, "dictionaries" => [], "files" => []}, manifest(backup))
    assert File.directory?(File.join(@target, "fixture.userdb"))
    assert_equal entry_map(SOURCE_ENTRIES), exported_entries(@target)
    restored_snapshot = native_snapshot(@target)
    assert_equal expected_snapshot, restored_snapshot
    assert_snapshot_fields_preserved(snapshot_rows(source_snapshot), restored_snapshot)
    assert_equal original_installation, File.binread(File.join(@target, "installation.yaml"))
    %w[custom_phrase.txt nested/fixture.dict.yaml].each do |relative|
      assert_equal File.binread(File.join(@source, relative)), File.binread(File.join(@target, relative))
    end
  end

  def test_native_restore_handles_multiple_dictionaries_without_leaving_temporary_database
    require_manager
    import_entries(@source, SOURCE_ENTRIES)
    input = write(@source, "second-input.tsv", TARGET_ENTRIES.map { |row| row.join("\t") }.join("\n") + "\n")
    native(@source, "--import", "fixture_second", input)
    bundle = quietly { source_service.export }
    assert_equal %w[fixture fixture_second], manifest(bundle).fetch("dictionaries")
    quietly { target_service.restore(bundle) }
    assert_equal entry_map(SOURCE_ENTRIES), exported_entries(@target)
    native(@target, "--backup", "fixture_second")
    rows = snapshot_rows(File.join(@target, "sync/test-target-device/fixture_second.userdb.txt"))
    assert_equal TARGET_ENTRIES.length, rows.length
    assert_equal "13", rows.fetch(["mubiao jia", "测试目标假词"]).fetch("c")
    refute File.exist?(File.join(@target, ".temp.userdb"))
  end

  def test_export_without_git_copies_all_personal_dictionaries_and_phrases_only
    files = ["fixture.dict.yaml", "nested/other.dict.yaml", "custom_phrase.txt", "custom_phrase_extra.txt"]
    files.each { |relative| write(@source, relative, "测试个人文件\n") }
    %w[default.yaml build/compiled.bin notes.txt fixture.userdb.txt].each do |relative|
      write(@source, relative, "fixture non-personal content\n")
    end
    service = source_service(manager: missing_manager)
    bundle = quietly { service.export }
    assert_equal({"version" => 1, "dictionaries" => [], "files" => files.sort}, manifest(bundle))
    assert_equal files.sort, Dir.glob("**/*", base: File.join(bundle, "files")).select { |p| File.file?(File.join(bundle, "files", p)) }.sort
    files.each { |relative| assert_equal File.binread(File.join(@source, relative)), File.binread(File.join(bundle, "files", relative)) }
    refute File.exist?(File.join(bundle, "files/installation.yaml"))
  end

  def test_git_filter_exports_changed_and_untracked_dictionaries_but_not_unchanged_ones
    FileUtils.mkdir_p(File.join(@source, ".git"))
    %w[unchanged.dict.yaml changed.dict.yaml staged.dict.yaml untracked.dict.yaml custom_phrase.txt].each do |relative|
      write(@source, relative, "测试筛选文件\n")
    end
    service = source_service(manager: missing_manager)
    calls = []
    output = lambda do |*arguments|
      calls << arguments
      case arguments
      when ["ls-files", "-z"]
        "unchanged.dict.yaml\0changed.dict.yaml\0staged.dict.yaml\0custom_phrase.txt\0"
      when ["diff", "--name-only", "-z", "HEAD", "--"]
        "changed.dict.yaml\0staged.dict.yaml\0"
      else
        flunk "Unexpected git arguments: #{arguments.inspect}"
      end
    end
    bundle = service.stub(:git_output, output) { quietly { service.export } }
    assert_equal %w[changed.dict.yaml custom_phrase.txt staged.dict.yaml untracked.dict.yaml], manifest(bundle).fetch("files")
    assert_equal 2, calls.length
  end

  def test_restore_backs_up_overwritten_tracked_dictionary_even_when_git_filter_excludes_it
    write(@source, "fixture.dict.yaml", dictionary("测试新词典"))
    write(@source, "custom_phrase.txt", "测试新短语\tnew\t2\n")
    bundle = quietly { source_service.export }
    write(@target, "fixture.dict.yaml", dictionary("测试原词典"))
    write(@target, "custom_phrase.txt", "测试原短语\told\t4\n")
    write(@target, "custom_phrase_unrelated.txt", "测试保留短语\tkeep\t6\n")
    FileUtils.mkdir_p(File.join(@target, ".git"))
    original = %w[fixture.dict.yaml custom_phrase.txt custom_phrase_unrelated.txt].map do |relative|
      [relative, File.binread(File.join(@target, relative))]
    end.to_h
    service = target_service(manager: missing_manager)
    output = lambda { |*args| args.first == "ls-files" ? "fixture.dict.yaml\0" : "" }
    backup = service.stub(:git_output, output) { quietly { service.restore(bundle) } }
    original.each { |relative, bytes| assert_equal bytes, File.binread(File.join(backup, "files", relative)) }
    assert_equal original.fetch("custom_phrase_unrelated.txt"), File.binread(File.join(@target, "custom_phrase_unrelated.txt"))
    %w[fixture.dict.yaml custom_phrase.txt].each do |relative|
      assert_equal File.binread(File.join(@source, relative)), File.binread(File.join(@target, relative))
    end
  end

  def test_failed_restore_file_write_preserves_original_and_before_restore_backup
    bundle = personal_bundle
    original = "测试原有短语\told\t4\n".b
    write(@target, "custom_phrase.txt", original)
    original_copy = FileUtils.method(:cp)
    copy = lambda do |source, destination, **options|
      raise Errno::ENOSPC, "disk full" if source.start_with?(File.join(bundle, "files"))
      original_copy.call(source, destination, **options)
    end
    output = FileUtils.stub(:cp, copy) do
      capture_io { assert_raises(Errno::ENOSPC) { target_service.restore(bundle) } }.first
    end
    assert_equal original, File.binread(File.join(@target, "custom_phrase.txt"))
    backups = target_service.bundles
    assert_equal 1, backups.length
    assert_equal original, File.binread(File.join(backups.first, "files/custom_phrase.txt"))
    assert_includes output, "Restore stopped"
    assert_includes output, backups.first
    assert_empty Dir.glob(".rime-restore-*", base: @target)
  end

  def test_bundles_lists_only_completed_non_symlink_directories_in_reverse_order
    service = source_service
    assert_empty service.bundles
    write(@source, "custom_phrase.txt", "测试清单短语\n")
    first = quietly { service.export }
    second = quietly { service.export }
    FileUtils.mkdir_p(File.join(@exports, "incomplete"))
    write(@exports, "ordinary-file", "not a bundle")
    File.symlink(first, File.join(@exports, "linked-bundle"))
    assert_equal [first, second].sort.reverse, service.bundles
  end

  def test_restore_rejects_manifest_file_path_traversal_and_absolute_paths
    bundle = personal_bundle
    ["../outside.dict.yaml", "/absolute.dict.yaml", "nested/../../outside.dict.yaml",
      "nested\\outside.dict.yaml", "nested//bad.dict.yaml", "nested/./bad.dict.yaml",
      "C:/outside.dict.yaml", "nested/\u0000bad.dict.yaml"].each do |relative|
      write_manifest(bundle, "version" => 1, "dictionaries" => [], "files" => [relative])
      assert_rejected_without_changes(bundle, /Unsafe path/)
    end
  end

  def test_restore_rejects_invalid_dictionary_names
    bundle = personal_bundle
    ["../outside", "/absolute", "nested/name", ".hidden", "bad\\name", "fixture.userdb.x", "fixture.userdb", nil].each do |name|
      write_manifest(bundle, "version" => 1, "dictionaries" => [name], "files" => [])
      assert_rejected_without_changes(bundle, /Invalid user dictionary name/)
    end
  end

  def test_restore_rejects_forged_snapshot_db_name
    bundle = snapshot_bundle
    ["another_dictionary", "../outside", "/absolute", " fixture", "fixture ", "fixture\t"].each do |name|
      write(bundle, "dictionaries/fixture.userdb.txt", snapshot_text(name))
      assert_rejected_without_changes(bundle, /Snapshot metadata/)
    end
  end

  def test_restore_rejects_duplicate_snapshot_metadata_and_wrong_db_type
    bundle = snapshot_bundle
    [snapshot_text + "#@/db_name\tfixture\n", snapshot_text + "#@/db_type\tuserdb\n",
      snapshot_text.sub("#@/db_type\tuserdb", "#@/db_type\treverse_lookup")].each do |content|
      write(bundle, "dictionaries/fixture.userdb.txt", content)
      assert_rejected_without_changes(bundle, /Snapshot metadata/)
    end
  end

  def test_restore_rejects_incomplete_or_malformed_snapshot_records
    bundle = snapshot_bundle
    [snapshot_text.chomp, snapshot_text.sub("c=7 d=8e-08 t=0", "c=7 d=8e-08"),
      snapshot_text + "partial row\n", snapshot_text + "bad\xff\n".b.force_encoding("UTF-8")].each do |content|
      write(bundle, "dictionaries/fixture.userdb.txt", content)
      assert_rejected_without_changes(bundle, /Incomplete or malformed dictionary snapshot/)
    end
  end

  def test_restore_rejects_malformed_unsupported_and_duplicate_manifests
    bundle = personal_bundle
    ["{not-json", "null", {"version" => 2, "files" => [], "dictionaries" => []},
      {"version" => 1, "files" => "custom_phrase.txt", "dictionaries" => []},
      {"version" => 1, "files" => ["custom_phrase.txt", "custom_phrase.txt"], "dictionaries" => []},
      {"version" => 1, "files" => [], "dictionaries" => ["fixture", "fixture"]}].each do |data|
      write(bundle, "manifest.json", data.is_a?(String) ? data : JSON.generate(data))
      assert_rejected_without_changes(bundle)
    end
  end

  def test_restore_rejects_missing_or_unsupported_personal_files
    bundle = personal_bundle
    ["missing.dict.yaml", "installation.yaml"].each do |relative|
      write_manifest(bundle, "version" => 1, "dictionaries" => [], "files" => [relative])
      assert_rejected_without_changes(bundle)
    end
  end

  def test_restore_rejects_symlink_bundle_root
    bundle = personal_bundle
    link = File.join(@tmp, "linked-bundle")
    File.symlink(bundle, link)
    assert_rejected_without_changes(link, /Symlink|symlink/)
  end

  def test_restore_rejects_symlink_manifest_personal_file_and_parent
    bundle = personal_bundle
    ["manifest.json", "files/custom_phrase.txt", "files"].each_with_index do |relative, index|
      original = File.join(bundle, relative)
      moved = File.join(@tmp, "symlink-original-#{index}")
      File.rename(original, moved)
      File.symlink(moved, original)
      assert_rejected_without_changes(bundle, /symlink/)
      File.unlink(original)
      File.rename(moved, original)
    end
  end

  def test_restore_rejects_symlink_snapshot_and_snapshot_parent
    bundle = snapshot_bundle
    ["dictionaries/fixture.userdb.txt", "dictionaries"].each_with_index do |relative, index|
      original = File.join(bundle, relative)
      moved = File.join(@tmp, "snapshot-original-#{index}")
      File.rename(original, moved)
      File.symlink(moved, original)
      assert_rejected_without_changes(bundle, /symlink/)
      File.unlink(original)
      File.rename(moved, original)
    end
  end

  def test_restore_rejects_symlink_target_file_or_parent_without_overwriting_external_fixture
    write(@source, "nested/fixture.dict.yaml", dictionary("测试来源词"))
    bundle = quietly { source_service.export }
    outside = File.join(@tmp, "outside")
    external = write(outside, "fixture.dict.yaml", dictionary("测试外部词"))
    original = File.binread(external)
    File.symlink(outside, File.join(@target, "nested"))
    assert_rejected_without_changes(bundle, /symlink/)
    assert_equal original, File.binread(external)
    File.unlink(File.join(@target, "nested"))
    FileUtils.mkdir_p(File.join(@target, "nested"))
    File.symlink(external, File.join(@target, "nested/fixture.dict.yaml"))
    assert_rejected_without_changes(bundle, /symlink/)
    assert_equal original, File.binread(external)
  end

  def test_restore_rejects_directory_in_place_of_target_file
    bundle = personal_bundle
    FileUtils.mkdir_p(File.join(@target, "custom_phrase.txt"))
    assert_rejected_without_changes(bundle, /non-regular file/)
  end

  def test_export_rejects_symlink_personal_file_and_user_database
    outside = write(@tmp, "outside.txt", "测试外部假词\n")
    link = File.join(@source, "custom_phrase.txt")
    File.symlink(outside, link)
    assert_raises(ERROR) { quietly { source_service.export } }
    assert_empty source_service.bundles
    File.unlink(link)
    outside_db = File.join(@tmp, "outside.userdb")
    FileUtils.mkdir_p(outside_db)
    File.symlink(outside_db, File.join(@source, "fixture.userdb"))
    assert_raises(ERROR) { quietly { source_service.export } }
    assert_empty source_service.bundles
    assert_empty Dir.children(outside_db)
  end

  def test_restore_rejects_existing_native_temporary_database
    bundle = snapshot_bundle
    path = File.join(@target, ".temp.userdb")
    FileUtils.mkdir_p(path)
    write(path, "sentinel", "temporary data to preserve")
    assert_rejected_without_changes(bundle, /Refusing native restore/)
  end

  def test_restore_rejects_native_temporary_database_symlink
    bundle = snapshot_bundle
    outside = File.join(@tmp, "external-database")
    write(outside, "sentinel", "external data to preserve")
    original = tree_state(outside)
    File.symlink(outside, File.join(@target, ".temp.userdb"))
    assert_rejected_without_changes(bundle, /Refusing native restore/)
    assert_equal original, tree_state(outside)
  end

  def test_export_rejects_dictionary_names_native_rime_would_truncate
    FileUtils.mkdir_p(File.join(@source, "fixture.userdb.x.userdb"))
    error = assert_raises(ERROR) { quietly { source_service.export } }
    assert_match(/native Rime would truncate/, error.message)
    assert_empty source_service.bundles
  end

  def test_export_rejects_symlink_backup_root
    FileUtils.mkdir_p(@backups)
    File.symlink(@backups, @exports)
    assert_raises(ERROR) { quietly { source_service.export } }
    assert_empty Dir.children(@backups)
  end

  def test_export_without_manager_reports_error_and_leaves_no_bundle
    FileUtils.mkdir_p(File.join(@source, "fixture.userdb"))
    service = source_service(manager: missing_manager)
    error = assert_raises(ERROR) { quietly { service.export } }
    assert_match(/rime_dict_manager is required/, error.message)
    assert_empty service.bundles
    refute File.exist?(@exports)
  end

  def test_restore_without_manager_fails_before_backup_or_personal_file_replacement
    bundle = snapshot_bundle
    write(bundle, "files/custom_phrase.txt", "测试替换短语\n")
    data = manifest(bundle)
    data["files"] = ["custom_phrase.txt"]
    write_manifest(bundle, data)
    write(@target, "custom_phrase.txt", "测试原有短语\n")
    assert_rejected_without_changes(bundle, /rime_dict_manager is required/, target_service(manager: missing_manager))
  end

  def test_failed_manager_export_removes_partial_bundle_and_preserves_completed_bundles
    write(@source, "custom_phrase.txt", "测试有效备份\n")
    completed = quietly { source_service.export }
    FileUtils.mkdir_p(File.join(@source, "fixture.userdb"))
    executable = write(@tmp, "failing-manager", "#!/bin/sh\nprintf '%s\\n' 'fixture manager failure' >&2\nexit 23\n")
    File.chmod(0700, executable)
    service = source_service(manager: executable)
    error = assert_raises(ERROR) { quietly { service.export } }
    assert_match(/fixture manager failure/, error.message)
    assert_equal [completed], service.bundles
    assert_equal [File.basename(completed)], Dir.children(@exports)
  end

  def test_successful_manager_exit_without_snapshot_does_not_leave_a_valid_bundle
    FileUtils.mkdir_p(File.join(@source, "fixture.userdb"))
    executable = write(@tmp, "empty-manager", "#!/bin/sh\nexit 0\n")
    File.chmod(0700, executable)
    service = source_service(manager: executable)
    error = assert_raises(ERROR) { quietly { service.export } }
    assert_match(/Missing dictionary snapshot/, error.message)
    assert_empty service.bundles
    assert_empty Dir.children(@exports)
  end

  def test_successful_manager_exit_cannot_reuse_an_old_snapshot
    FileUtils.mkdir_p(File.join(@source, "fixture.userdb"))
    snapshot = write(@source, "sync/test-device/fixture.userdb.txt", snapshot_text)
    original = File.binread(snapshot)
    executable = write(@tmp, "empty-manager", "#!/bin/sh\nexit 0\n")
    File.chmod(0700, executable)
    service = source_service(manager: executable)
    error = assert_raises(ERROR) { quietly { service.export } }
    assert_match(/Missing dictionary snapshot/, error.message)
    assert_equal original, File.binread(snapshot)
    assert_empty service.bundles
    assert_empty Dir.glob("sync/test-device/.rime-snapshot-*", base: @source)
  end

  def test_restore_stops_if_before_restore_backup_does_not_generate_a_new_snapshot
    bundle = snapshot_bundle
    FileUtils.mkdir_p(File.join(@target, "fixture.userdb"))
    write(@target, "sync/test-target-device/fixture.userdb.txt", snapshot_text)
    service = target_service
    calls = []
    service.stub(:run_manager, ->(*arguments) { calls << arguments }) do
      assert_rejected_without_changes(bundle, /Missing dictionary snapshot/, service)
    end
    assert_equal [["--backup", "fixture"]], calls
  end

  def test_failed_snapshot_validation_preserves_previous_sync_snapshot
    FileUtils.mkdir_p(File.join(@source, "fixture.userdb"))
    snapshot = write(@source, "sync/test-device/fixture.userdb.txt", snapshot_text)
    original = File.binread(snapshot)
    service = source_service
    manager = lambda do |*arguments|
      assert_equal ["--backup", "fixture"], arguments
      File.write(snapshot, "incomplete snapshot")
    end
    service.stub(:run_manager, manager) do
      error = assert_raises(ERROR) { quietly { service.export } }
      assert_match(/Incomplete or malformed dictionary snapshot/, error.message)
    end
    assert_equal original, File.binread(snapshot)
    assert_empty service.bundles
  end

  def test_native_export_refreshes_read_only_previous_snapshot
    require_manager
    import_entries(@source, SOURCE_ENTRIES)
    quietly { source_service.export }
    snapshot = File.join(@source, "sync/test-device/fixture.userdb.txt")
    File.chmod(0400, snapshot)
    import_entries(@source, TARGET_ENTRIES)
    bundle = quietly { source_service.export }
    rows = snapshot_rows(File.join(bundle, "dictionaries/fixture.userdb.txt"))
    assert_equal SOURCE_ENTRIES.length + TARGET_ENTRIES.length, rows.length
    assert_equal rows, snapshot_rows(snapshot)
    assert_empty Dir.glob("sync/test-device/.rime-snapshot-*", base: @source)
  end

  def test_locked_native_export_rejects_even_a_stale_snapshot_and_removes_partial_bundle
    require_manager
    import_entries(@source, SOURCE_ENTRIES)
    service = source_service
    completed = quietly { service.export }
    snapshot = File.join(@source, "sync/test-device/fixture.userdb.txt")
    original = File.binread(snapshot)
    with_database_lock(@source) do
      error = assert_raises(ERROR) { quietly { service.export } }
      assert_match(/locked database|operation failed/i, error.message)
    end
    assert_equal [completed], service.bundles
    assert_equal [File.basename(completed)], Dir.children(@exports)
    assert_equal original, File.binread(snapshot)
    assert_equal entry_map(SOURCE_ENTRIES), exported_entries(@source)
  end

  def test_locked_native_restore_stops_before_overwriting_files_or_merging_entries
    require_manager
    import_entries(@source, SOURCE_ENTRIES)
    import_entries(@target, TARGET_ENTRIES)
    write(@source, "custom_phrase.txt", "测试新短语\n")
    write(@target, "custom_phrase.txt", "测试旧短语\n")
    bundle = quietly { source_service.export }
    original = File.binread(File.join(@target, "custom_phrase.txt"))
    original_installation = File.binread(File.join(@target, "installation.yaml"))
    with_database_lock(@target) do
      error = assert_raises(ERROR) { quietly { target_service.restore(bundle) } }
      assert_match(/locked database|operation failed/i, error.message)
    end
    assert_empty target_service.bundles
    assert_empty Dir.children(@backups) if File.directory?(@backups)
    assert_equal original, File.binread(File.join(@target, "custom_phrase.txt"))
    assert_equal original_installation, File.binread(File.join(@target, "installation.yaml"))
    assert_equal entry_map(TARGET_ENTRIES), exported_entries(@target)
  end

  private

  def source_service(manager: MANAGER)
    RimeDeploy::PersonalData.new(@source, backup_root: @exports, manager: manager)
  end

  def target_service(manager: MANAGER)
    RimeDeploy::PersonalData.new(@target, backup_root: @backups, manager: manager)
  end

  def missing_manager
    File.join(@tmp, "nonexistent-rime-dict-manager")
  end

  def write(base, relative, content)
    path = File.expand_path(relative, base)
    raise "Fixture escaped temporary directory" unless path.start_with?(@tmp + File::SEPARATOR)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def quietly
    result = nil
    capture_io { result = yield }
    result
  end

  def dictionary(word)
    "---\nname: fixture\nversion: '1'\nsort: by_weight\n...\n#{word}\tceshi\t8\n"
  end

  def manifest(bundle)
    JSON.parse(File.read(File.join(bundle, "manifest.json"), encoding: "UTF-8"))
  end

  def write_manifest(bundle, data)
    write(bundle, "manifest.json", JSON.generate(data))
  end

  def personal_bundle
    write(@source, "custom_phrase.txt", "测试包内短语\n")
    quietly { source_service.export }
  end

  def snapshot_text(name = "fixture")
    "# Rime user dictionary\n#@/db_name\t#{name}\n#@/db_type\tuserdb\n#@/user_id\ttest-device\nceshi jia \t测试假词甲\tc=7 d=8e-08 t=0\n"
  end

  def snapshot_bundle
    bundle = File.join(@tmp, "synthetic-bundle")
    write(bundle, "dictionaries/fixture.userdb.txt", snapshot_text)
    write_manifest(bundle, "version" => 1, "dictionaries" => ["fixture"], "files" => [])
    bundle
  end

  def tree_state(directory)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: directory).sort.map do |relative|
      path = File.join(directory, relative)
      value = if File.symlink?(path)
        [:symlink, File.readlink(path)]
      elsif File.file?(path)
        [:file, File.binread(path)]
      else
        [:directory]
      end
      [relative, value]
    end
  end

  def assert_rejected_without_changes(bundle, message = nil, service = target_service)
    original = tree_state(@target)
    backups = service.bundles
    error = assert_raises(ERROR) { quietly { service.restore(bundle) } }
    assert_match(message, error.message) if message
    assert_equal original, tree_state(@target), "Rejected bundle changed the target"
    assert_equal backups, service.bundles, "Rejected bundle created a backup"
    error
  end

  def require_manager
    skip "Native rime_dict_manager is not installed" unless File.file?(MANAGER) && File.executable?(MANAGER)
  end

  def native(directory, *arguments)
    raise "Native CLI must only access test fixtures" unless [@source, @target, @control].compact.include?(directory)
    output, error, status = Open3.capture3({"GLOG_logtostderr" => "1"}, MANAGER, *arguments, chdir: directory)
    assert status.success?, "Native fixture command #{arguments.first} failed: #{error}"
    output
  end

  def import_entries(directory, entries)
    input = write(directory, "fixture-input.tsv", entries.map { |row| row.join("\t") }.join("\n") + "\n")
    native(directory, "--import", "fixture", input)
    assert File.directory?(File.join(directory, "fixture.userdb"))
  end

  def entry_map(entries)
    entries.map { |word, code, count| [[word, code], count] }.to_h
  end

  def exported_entries(directory)
    output = File.join(directory, "fixture-output.tsv")
    native(directory, "--export", "fixture", output)
    rows = File.readlines(output, encoding: "UTF-8").reject { |line| line.start_with?("#") || line.strip.empty? }
    rows.map do |line|
      word, code, count = line.chomp.split("\t")
      [[word, code], Integer(count)]
    end.to_h
  end

  def native_snapshot(directory)
    native(directory, "--backup", "fixture")
    id = directory == @source ? "test-device" : "test-target-device"
    snapshot_rows(File.join(directory, "sync", id, "fixture.userdb.txt"))
  end

  def directly_restored_snapshot(snapshot, original_entries)
    @control = File.join(@tmp, "native-control")
    write(@control, "installation.yaml", "installation_id: test-target-device\nsync_dir: sync\n")
    import_entries(@control, original_entries) unless original_entries.empty?
    native(@control, "--restore", snapshot)
    native_snapshot(@control)
  end

  def assert_snapshot_fields_preserved(original, restored)
    original.each do |key, fields|
      actual = restored.fetch(key)
      assert_equal fields.keys.sort, actual.keys.sort
      assert_equal fields.fetch("c"), actual.fetch("c")
      assert_equal fields.fetch("d"), actual.fetch("d")
      # Native restore rebases ticks; the independent CLI control checks the exact result.
      assert_operator Integer(actual.fetch("t")), :>=, Integer(fields.fetch("t"))
    end
  end

  def metadata(path)
    File.readlines(path, encoding: "UTF-8").select { |line| line.start_with?("#@/") }.map do |line|
      key, value = line.chomp.delete_prefix("#@/").split("\t", 2)
      [key, value]
    end.to_h
  end

  def snapshot_rows(path)
    File.readlines(path, encoding: "UTF-8").reject { |line| line.start_with?("#") || line.strip.empty? }.map do |line|
      code, word, fields = line.chomp.split("\t")
      [[code.strip, word], fields.split(" ").map { |field| field.split("=", 2) }.to_h]
    end.to_h
  end

  def with_database_lock(directory)
    python = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "python3") }.find do |path|
      File.file?(path) && File.executable?(path)
    end
    skip "Python 3 is required for the native POSIX lock fixture" unless python
    lock_path = File.join(directory, "fixture.userdb/LOCK")
    assert File.file?(lock_path), "Only lock a database created by this test"
    script = "import fcntl, sys\nwith open(sys.argv[1], 'a+b') as lock:\n    fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)\n    print('locked', flush=True)\n    sys.stdin.read()\n"
    Open3.popen3(python, "-c", script, lock_path, chdir: @tmp) do |input, output, error, process|
      begin
        ready = Timeout.timeout(10) { output.gets }
        assert_equal "locked\n", ready, "Python could not acquire the fixture database lock"
        yield
      ensure
        input.close unless input.closed?
        begin
          status = Timeout.timeout(10) { process.value }
          assert status.success?, "Lock fixture failed: #{error.read}"
        rescue Timeout::Error
          Process.kill("KILL", process.pid)
          process.value
          flunk "Lock fixture did not terminate"
        end
      end
    end
  end
end
