require 'katello_test_helper'

module ::Actions::Katello::ContentViewVersion
  class TestBase < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures
    include Support::Actions::RemoteAction
    include FactoryBot::Syntax::Methods

    before do
      set_user
    end
  end

  class IncrementalUpdateTest < TestBase
    let(:action_class) { ::Actions::Katello::ContentViewVersion::IncrementalUpdate }
    let(:action) { create_action action_class }

    let(:library) do
      katello_environments(:library)
    end

    let(:content_view_version) do
      katello_content_view_versions(:library_view_version_2)
    end

    let(:library_repo) do
      katello_repositories(:fedora_17_x86_64)
    end

    it 'outputs auto publish data' do
      cv = content_view_version.content_view
      task = ForemanTasks::Task::DynflowTask.create!(state: :success, result: "good")
      action.stubs(:task).returns(task)
      action.expects(:action_subject).with(cv)
      repository_mapping = {}
      Dynflow::Testing::DummyPlannedAction.any_instance.stubs(:repository_mapping).returns(repository_mapping)
      composites = [{id: 1}, {id: 2}, {id: 3}]
      Katello::ContentView.any_instance.expects(:auto_publish_composites).returns(composites)

      plan_action(action, content_view_version, [])
      run = run_action(action)

      assert_equal run.input[:new_content_view_version_id], run.output[:auto_publish_content_view_version_id]
      assert_equal [1, 2, 3], run.output[:auto_publish_content_view_ids]
    end

    it 'plans' do
      SmartProxy.any_instance.stubs(:pulp3_support?).returns(false)
      stub_remote_user
      @rpm = library_repo.rpms.first

      new_repo = ::Katello::Repository.new(:pulp_id => 387, :library_instance_id => library_repo.id, :root => library_repo.root)
      repository_mapping = {}
      repository_mapping[[library_repo]] = new_repo
      Dynflow::Testing::DummyPlannedAction.any_instance.stubs(:repository_mapping).returns(repository_mapping)
      ::Actions::Katello::ContentViewVersion::IncrementalUpdate.any_instance.expects(:repos_to_copy).returns(repository_mapping.keys)
      task = ForemanTasks::Task::DynflowTask.create!(state: :success, result: "good")
      action.stubs(:task).returns(task)
      action.expects(:action_subject).with(content_view_version.content_view)
      plan_action(action, content_view_version, [library], :content => {:package_ids => [@rpm.id]})

      assert_action_planned_with(action, ::Actions::Katello::Repository::MetadataGenerate, new_repo)
      assert_action_planned_with(action, ::Actions::Katello::Repository::IndexContent, id: new_repo.id)
    end

    describe 'pulp3' do
      let(:old_rpm) do
        katello_rpms(:one)
      end

      let(:new_repo) do
        ::Katello::Repository.new(:pulp_id => 387, :library_instance_id => library_repo.id, :root => library_repo.root)
      end

      let(:library_repo) do
        katello_repositories(:rhel_7_x86_64)
      end

      def pulp3_cvv_setup
        SmartProxy.any_instance.stubs(:pulp3_support?).returns(true)
        content_view_version.repositories.where(version_href: nil).update(version_href: 'not-nil-href/1/')
        stub_remote_user

        repository_mapping = {}
        cv_version = katello_content_view_versions(:library_view_version_2)
        new_repo.update(content_view_version_id: cv_version.id, relative_path: "blah")
        new_repo.update(version_href: "/test/versions/1/")
        library_repo.update(version_href: "/library_test/versions/1/")
        new_repo.save!
        repository_mapping[[library_repo]] = new_repo
        Dynflow::Testing::DummyPlannedAction.any_instance.stubs(:repository_mapping).returns(repository_mapping)
        ::Actions::Katello::ContentViewVersion::IncrementalUpdate.any_instance.expects(:repos_to_copy).returns(repository_mapping.keys)
        task = ForemanTasks::Task::DynflowTask.create!(state: :success, result: "good")
        action.stubs(:task).returns(task)
        action.expects(:action_subject).with(content_view_version.content_view)
      end

      it 'respects dep solving false' do
        pulp3_cvv_setup
        ::Katello::Repository.any_instance.stubs(:soft_copy_of_library?).returns(true)
        plan_action(action, content_view_version, [library], :resolve_dependencies => false, :content => {:package_ids => [old_rpm.id]})

        pulp3_repo_map = {}
        pulp3_repo_map[[library_repo.id]] = { :dest_repo => new_repo.id, :base_version => nil }
        assert_action_planned_with(action, ::Actions::Pulp3::Repository::MultiCopyUnits,
                                  pulp3_repo_map,
                                  { :debs => [], :errata => [], :rpms => [old_rpm.id] },
                                  :dependency_solving => false)
        assert_action_planned_with(action, ::Actions::Pulp3::Repository::CopyContent, library_repo, SmartProxy.pulp_primary, new_repo, copy_all: true, remove_all: true)
        assert_action_planned_with(action, ::Actions::Katello::Repository::MetadataGenerate, new_repo)
        assert_action_planned_with(action, ::Actions::Katello::Repository::IndexContent, id: new_repo.id)
      end

      it 'defers clone metadata for repos updated via multicopy' do
        pulp3_cvv_setup
        ::Katello::Repository.any_instance.stubs(:soft_copy_of_library?).returns(false)
        ::Actions::Katello::Repository::CloneToVersion.any_instance.expects(:plan).with do |repositories, _version, destination_repo, options|
          repositories == [library_repo] &&
            destination_repo == new_repo &&
            options[:incremental] == true &&
            options[:generate_metadata] == false
        end

        plan_action(action, content_view_version, [library], :resolve_dependencies => false, :content => {:package_ids => [old_rpm.id]})

        assert_action_planned_with(action, ::Actions::Pulp3::Repository::MultiCopyUnits,
                                  { [library_repo.id] => { :dest_repo => new_repo.id, :base_version => 1, :base_repository_id => library_repo.id } },
                                  { :debs => [], :errata => [], :rpms => [old_rpm.id] },
                                  :dependency_solving => false)
        assert_action_planned_with(action, ::Actions::Katello::Repository::MetadataGenerate, new_repo)
      end

      it 'keeps clone metadata enabled when repo is not in version changing multicopy map' do
        pulp3_cvv_setup
        ::Katello::Repository.any_instance.stubs(:soft_copy_of_library?).returns(false)
        action.stubs(:pulp3_repo_mapping).returns({})
        ::Actions::Katello::Repository::CloneToVersion.any_instance.expects(:plan).with do |repositories, _version, destination_repo, options|
          repositories == [library_repo] &&
            destination_repo == new_repo &&
            options[:incremental] == true &&
            options[:generate_metadata] == true
        end

        plan_action(action, content_view_version, [library], :resolve_dependencies => false, :content => {:package_ids => [old_rpm.id]})

        refute_action_planned(action, ::Actions::Pulp3::Repository::MultiCopyUnits)
        refute_action_planned(action, ::Actions::Katello::Repository::MetadataGenerate)
      end

      it 'respects dep solving true' do
        pulp3_cvv_setup
        ::Katello::Repository.any_instance.stubs(:soft_copy_of_library?).returns(false)
        plan_action(action, content_view_version, [library], :resolve_dependencies => true, :content => {:package_ids => [old_rpm.id]})

        pulp3_repo_map = {}
        pulp3_repo_map[[library_repo.id]] = { :dest_repo => new_repo.id, :base_version => 1 }
        assert_action_planned_with(action, ::Actions::Pulp3::Repository::MultiCopyUnits,
                                  pulp3_repo_map,
                                  { :debs => [], :errata => [], :rpms => [old_rpm.id] },
                                  :dependency_solving => true)
        refute_action_planned(action, ::Actions::Pulp3::Repository::CopyContent)
      end

      it 'filters multicopy repo mapping to repos containing selected units' do
        old_version = katello_content_view_versions(:library_view_version_2)
        fedora_source = katello_repositories(:fedora_17_x86_64)
        rhel_source = katello_repositories(:rhel_6_x86_64)
        fedora_new_repo = ::Katello::Repository.new(library_instance_id: fedora_source.id, root: fedora_source.root)
        rhel_new_repo = ::Katello::Repository.new(library_instance_id: rhel_source.id, root: rhel_source.root)
        fedora_new_repo.id = 1001
        rhel_new_repo.id = 1002

        result = action.pulp3_repo_mapping(
          {
            [fedora_source] => fedora_new_repo,
            [rhel_source] => rhel_new_repo
          },
          old_version,
          { :errata => [], :debs => [], :rpms => [old_rpm.id] }
        )

        assert_equal [[fedora_source.id]], result.keys
        assert_equal fedora_new_repo.id, result[[fedora_source.id]][:dest_repo]
        refute result.key?([rhel_source.id])
      end
    end
  end
end
