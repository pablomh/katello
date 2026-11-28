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

      assert_action_planned(action, ::Actions::Katello::Repository::CloneToVersion)
      refute_action_planned(action, ::Actions::Katello::Repository::MetadataGenerate)
      refute_action_planned(action, ::Actions::Katello::Repository::IndexContent)
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
        Dynflow::Testing::DummyPlannedAction.any_instance.stubs(:save_versions_output).returns(save_versions_output)
      end

      let(:save_versions_output) do
        Dynflow::ExecutionPlan::OutputReference.new('1', 2, 3)
      end

      it 'plans nothing when the selection resolves to no copyable content' do
        pulp3_cvv_setup
        ::Katello::Repository.any_instance.stubs(:soft_copy_of_library?).returns(true)
        action.expects(:plan_self).with do |input|
          input[:copy_action_outputs] == [] &&
            input[:changed_repository_ids] == [] &&
            input[:adopted_repository_ids] == []
        end

        plan_action(action, content_view_version, [library],
                    :resolve_dependencies => false, :content => {:package_ids => [999_999_999]})

        refute_action_planned(action, ::Actions::Pulp3::Repository::MultiCopyUnits)
      end

      it 'respects dep solving false' do
        pulp3_cvv_setup
        ::Katello::RepositoryRpm.create!(:repository_id => library_repo.id, :rpm_id => old_rpm.id)
        ::Katello::Repository.any_instance.stubs(:soft_copy_of_library?).returns(true)
        plan_action(action, content_view_version, [library], :resolve_dependencies => false, :content => {:package_ids => [old_rpm.id]})

        pulp3_repo_map = {}
        pulp3_repo_map[[library_repo.id]] = { :dest_repo => new_repo.id, :base_version => nil }
        assert_action_planned_with(action, ::Actions::Pulp3::Repository::MultiCopyUnits) do |repo_map, unit_map, options|
          repo_map == pulp3_repo_map && unit_map == { :debs => [], :errata => [], :rpms => [old_rpm.id] } &&
            options[:dependency_solving] == false && options[:incremental_update] &&
            options[:seed_tasks].keys == [new_repo.id.to_s]
        end
        assert_action_planned_with(action, ::Actions::Pulp3::Repository::CopyVersion, library_repo, SmartProxy.pulp_primary, new_repo)
        refute_action_planned(action, ::Actions::Pulp3::Repository::CopyContent)
        reference = action.input[:changed_repository_ids].first
        assert_instance_of Dynflow::ExecutionPlan::OutputReference, reference
        persistence = mock
        persistence.stubs(:adapter).returns(mock(:load_action => { :output => { 'updated_repositories' => [new_repo.id] } }))
        assert_equal [new_repo.id], Dynflow::ExecutionPlan::OutputReference.dereference(reference, persistence)
        assert_action_planned_with(action, ::Actions::Katello::Repository::MetadataGenerate) do |plan_input|
          repo, options = plan_input
          repo == new_repo && options[:contents_changed].subkeys == ['changed_repositories', new_repo.id.to_s]
        end
        refute_action_planned(action, ::Actions::Katello::Repository::IndexContent)
      end

      it 'skips repositories holding none of the selected units' do
        pulp3_cvv_setup
        ::Katello::Repository.any_instance.stubs(:soft_copy_of_library?).returns(true)
        plan_action(action, content_view_version, [library], :resolve_dependencies => false, :content => {:package_ids => [old_rpm.id]})

        refute_action_planned(action, ::Actions::Pulp3::Repository::MultiCopyUnits)
        refute_action_planned(action, ::Actions::Pulp3::Repository::CopyVersion)
        refute_action_planned(action, ::Actions::Katello::Repository::MetadataGenerate)
      end

      it 'respects dep solving true' do
        pulp3_cvv_setup
        ::Katello::Repository.any_instance.stubs(:soft_copy_of_library?).returns(false)
        ::Katello::Pulp3::Repository.any_instance.stubs(:latest_version_href).returns(new_repo.version_href)
        plan_action(action, content_view_version, [library], :resolve_dependencies => true, :content => {:package_ids => [old_rpm.id]})

        pulp3_repo_map = {}
        pulp3_repo_map[[library_repo.id]] = { :dest_repo => new_repo.id, :base_version => 1 }
        assert_action_planned_with(action, ::Actions::Pulp3::Repository::MultiCopyUnits,
                                  pulp3_repo_map,
                                  { :debs => [], :errata => [], :rpms => [old_rpm.id] },
                                  :dependency_solving => true, :incremental_update => true, :seed_tasks => {})
        refute_action_planned(action, ::Actions::Pulp3::Repository::CopyContent)
        refute_action_planned(action, ::Actions::Pulp3::Repository::CopyVersion)
      end

      it 'seeds a base that is older than the latest version of its Pulp repository' do
        pulp3_cvv_setup
        ::Katello::Repository.any_instance.stubs(:soft_copy_of_library?).returns(false)
        ::Katello::Pulp3::Repository.any_instance.stubs(:latest_version_href).returns("/test/versions/5/")
        plan_action(action, content_view_version, [library], :resolve_dependencies => true, :content => {:package_ids => [old_rpm.id]})

        assert_action_planned_with(action, ::Actions::Pulp3::Repository::CopyVersion, library_repo, SmartProxy.pulp_primary, new_repo)
        assert_action_planned_with(action, ::Actions::Pulp3::Repository::MultiCopyUnits) do |repo_map, _unit_map, options|
          repo_map[[library_repo.id]][:base_version] == 1 && options[:seed_tasks].keys == [new_repo.id.to_s]
        end
      end
    end
  end
end
