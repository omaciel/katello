require 'katello_test_helper'

class Dynflow::Testing::DummyPlannedAction
  attr_accessor :error
end

module ::Actions::Katello::Repository
  class TestBase < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures
    include FactoryGirl::Syntax::Methods

    let(:action) { create_action action_class }
    let(:repository) { katello_repositories(:rhel_6_x86_64) }
    let(:custom_repository) { katello_repositories(:fedora_17_x86_64) }
    let(:puppet_repository) { katello_repositories(:p_forge) }
    let(:docker_repository) { katello_repositories(:redis) }

    before(:all) do
      set_user
      ::Katello::Product.any_instance.stubs(:certificate).returns(nil)
      ::Katello::Product.any_instance.stubs(:key).returns(nil)
    end
  end

  class CreateTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::Create }

    it 'plans' do
      repository.expects(:save!)
      action.expects(:action_subject).with(repository)
      action.execution_plan.stub_planned_action(::Actions::Katello::Product::ContentCreate) do |content_create|
        content_create.stubs(input: { content_id: 123 })
      end
      plan_action action, repository
    end

    it 'no clone flag means generate metadata in run phase' do
      repository.expects(:save!)
      action.expects(:action_subject).with(repository)
      action.execution_plan.stub_planned_action(::Actions::Katello::Product::ContentCreate) do |content_create|
        content_create.stubs(input: { content_id: 123 })
      end
      plan = plan_action action, repository
      run_action plan
      plan.run.label.must_equal "Actions::Katello::Repository::MetadataGenerate"
    end

    it 'clone flag disables metadata generation' do
      repository.expects(:save!)
      action.expects(:action_subject).with(repository)
      action.execution_plan.stub_planned_action(::Actions::Katello::Product::ContentCreate) do |content_create|
        content_create.stubs(input: { content_id: 123 })
      end
      plan = plan_action action, repository, true
      run_action plan
      plan.run.must_equal nil
    end
  end

  class CreateFailTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::Create }
    before do
      Dynflow::Testing::DummyPlannedAction.any_instance.stubs(:error).returns("ERROR")
    end

    it 'fails to plan' do
      repository.expects(:save!).never
    end
  end

  class DestroyTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::Destroy }
    let(:pulp_action_class) { ::Actions::Pulp::Repository::Destroy }
    let(:unpublished_repository) { katello_repositories(:fedora_17_unpublished) }
    let(:in_use_repository) { katello_repositories(:fedora_17_no_arch) }
    let(:published_repository) { katello_repositories(:rhel_6_x86_64) }

    it 'plans' do
      action = create_action action_class
      action.stubs(:action_subject).with(in_use_repository)
      in_use_repository.stubs(:assert_deletable).returns(true)
      action.expects(:plan_self)
      plan_action action, in_use_repository
      assert_action_planed_with action, pulp_action_class, pulp_id: in_use_repository.pulp_id

      refute_action_planed action, ::Actions::Katello::Product::ContentDestroy
    end

    it 'plans when custom and no clones' do
      action = create_action action_class
      action.stubs(:action_subject).with(unpublished_repository)
      action.expects(:plan_self)
      plan_action action, unpublished_repository

      assert_action_planed_with action, ::Actions::Katello::Product::ContentDestroy, unpublished_repository
    end

    it 'plan fails if repository is not deletable' do
      action = create_action action_class
      action.stubs(:action_subject).with(published_repository)

      assert_raises(RuntimeError) do
        plan_action action, published_repository
      end
    end
  end

  class DyscoverTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::Discover }
    let(:action_planned) { create_and_plan_action action_class, 'http://' }

    it 'plans' do
      assert_run_phase action_planned
    end

    it 'runs' do
      ::Katello::RepoDiscovery.
          expects(:new).
          returns(mock('discovery', run: nil))

      run_action action_planned
    end
  end

  class RemoveContentTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::RemoveContent }

    it 'plans' do
      to_remove = custom_repository.rpms
      uuids = to_remove.map(&:uuid)
      action.expects(:action_subject).with(custom_repository)
      plan_action action, custom_repository, to_remove

      assert_action_planed_with action, ::Actions::Pulp::Repository::RemoveRpm,
        pulp_id: custom_repository.pulp_id, clauses: {:association => {'unit_id' => {'$in' => uuids}}}
      assert_empty custom_repository.reload.rpms
    end
  end

  class RemoveDockerManifestsTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::RemoveContent }
    let(:docker_repo) { katello_repositories(:redis) }
    let(:uuids) { ["abc123", "def123", "ghi123"] }

    it 'plans' do
      uuids.each do |str|
        docker_repo.docker_manifests.create!(:name => str) do |manifest|
          manifest.uuid = str
        end
      end

      action.expects(:action_subject).with(docker_repo)
      plan_action action, docker_repo, docker_repo.docker_manifests
      assert_empty docker_repo.docker_manifests.reload
    end
  end

  class UploadFilesTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::UploadFiles }

    it 'plans' do
      file = File.join(::Katello::Engine.root, "test", "fixtures", "files", "puppet_module.tar.gz")
      action.expects(:action_subject).with(custom_repository)
      action.execution_plan.stub_planned_action(::Actions::Pulp::Repository::CreateUploadRequest) do |content_create|
        content_create.stubs(output: { upload_id: 123 })
      end

      plan_action action, custom_repository, [{:path => file, :filename => 'puppet_module.tar.gz'}]
      assert_action_planed(action, ::Actions::Pulp::Repository::CreateUploadRequest)
      assert_action_planed_with(action, ::Actions::Pulp::Repository::UploadFile,
                                upload_id: 123, file: File.join(Rails.root, 'tmp', 'uploads', 'puppet_module.tar.gz'))
      assert_action_planed_with(action, ::Actions::Pulp::Repository::DeleteUploadRequest,
                                upload_id: 123)
      assert_action_planed_with(action, ::Actions::Katello::Repository::FinishUpload,
                                custom_repository)
    end
  end

  class UploadErrataTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::UploadErrata }

    it 'plans' do
      action.expects(:action_subject).with(custom_repository)
      action.execution_plan.stub_planned_action(::Actions::Pulp::Repository::CreateUploadRequest) do |content_create|
        content_create.stubs(output: { upload_id: 123 })
      end

      errata = [{:unit_metadata => "our-metadata", :unit_key => "our-key"}]

      plan_action action, custom_repository, errata

      assert_action_planed(action, ::Actions::Pulp::Repository::CreateUploadRequest)

      assert_action_planed(action, ::Actions::Pulp::Repository::ImportUpload) do |(inputs)|
        inputs[:unit_type_id].must_equal 'erratum'
        inputs[:unit_metadata].must_equal 'our-metadata'
        inputs[:unit_key].must_equal "our-key"
        inputs[:upload_id].must_equal 123
      end

      assert_action_planed_with(action, ::Actions::Pulp::Repository::DeleteUploadRequest,
                                upload_id: 123)
    end
  end

  class FinishUploadTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::FinishUpload }

    it 'plans' do
      plan_action action, custom_repository
      assert_action_planed(action, ::Actions::Katello::Repository::MetadataGenerate)
    end

    it "does plan metadata generate for puppet repository" do
      plan_action action, puppet_repository
      assert_action_planed(action, ::Actions::Katello::Repository::MetadataGenerate)
    end
  end

  class IncrementalImportTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::IncrementalImport }

    it 'plans' do
      action.expects(:action_subject).with(custom_repository)
      # import_dir contains a tgz (ignored), a phony json (ignored), an rpm and
      # a real erratum json.
      import_dir = File.join(::Katello::Engine.root, "test", "fixtures", "files")
      plan_action action, custom_repository, import_dir

      assert_action_planed_with action, ::Actions::Katello::Repository::UploadFiles do |repo, rpm_filepaths|
        repo.must_equal custom_repository
        rpm_filepaths.length.must_equal 1
        rpm_filepaths.first[:filename].must_include "squirrel"
      end

      assert_action_planed_with action, ::Actions::Katello::Repository::UploadErrata do |repo, errata|
        repo.must_equal custom_repository
        errata.length.must_equal 1
        errata.first['unit_key']['id'].must_equal 'test'
      end
    end
  end

  class SyncTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::Sync }
    let(:pulp_action_class) { ::Actions::Pulp::Repository::Sync }

    it 'plans' do
      action = create_action action_class
      action.stubs(:action_subject).with(repository)
      plan_action action, repository

      assert_action_planed_with(action, pulp_action_class,
                                pulp_id: repository.pulp_id, task_id: nil, source_url: nil)
      assert_action_planed action, ::Actions::Katello::Repository::IndexContent
      assert_action_planed action, ::Actions::Katello::Repository::ImportApplicability
      assert_action_planed_with action, ::Actions::Katello::Repository::ErrataMail do |repo, _task_id, contents_changed|
        contents_changed.must_be_kind_of Dynflow::ExecutionPlan::OutputReference
        repo.id.must_equal repository.id
      end
    end

    it 'plans for incremental' do
      action = create_action action_class
      action.stubs(:action_subject).with(repository)
      plan_action action, repository, nil, 'file:///tmp/foo/', true

      # note the source URL is changed to a path
      assert_action_planed_with(action, ::Actions::Katello::Repository::IncrementalImport,
                                repository, '/tmp/foo/')
    end

    it 'plans for incremental, bad URL' do
      action = create_action action_class
      action.stubs(:action_subject).with(repository)

      assert_raises(RuntimeError) do
        plan_action action, repository, nil, 'http://wikipedia.org', true
      end
    end

    it 'passes the task id to pulp sync action when provided' do
      action = create_action action_class
      action.stubs(:action_subject).with(repository)
      plan_action action, repository, '123'

      assert_action_planed_with(action, pulp_action_class,
                                pulp_id: repository.pulp_id, task_id: '123', source_url: nil)
    end

    it 'passes the source URL to pulp sync action when provided' do
      action = create_action action_class
      action.stubs(:action_subject).with(repository)
      plan_action action, repository, nil, 'file:///tmp/'

      assert_action_planed_with(action, pulp_action_class,
                                pulp_id: repository.pulp_id, task_id: nil,
                                source_url: 'file:///tmp/')
    end

    describe 'progress' do
      let :action do
        create_action(action_class).tap do |action|
          action.stubs(planned_actions: [pulp_action])
        end
      end

      let(:pulp_action) { fixture_action(pulp_action_class, input: {pulp_id: repository.pulp_id}, output: fixture_variant) }

      describe 'successfully synchronized' do
        let(:fixture_variant) { :success }

        specify do
          action.humanized_output.must_equal "New packages: 32 (76.7 KB)."
        end
      end

      describe 'successfully synchronized without new packages' do
        let(:fixture_variant) { :success_no_packages }

        specify do
          action.humanized_output.must_equal "No new packages."
        end
      end

      describe 'syncing packages in progress' do
        let(:fixture_variant) { :progress_packages }

        specify do
          action.humanized_output.must_equal "New packages: 20/32 (48 KB/76.7 KB)."
        end

        specify do
          pulp_action.run_progress.must_be_within_delta 0.6256
        end
      end

      describe 'downloading metadata in progress' do
        let(:fixture_variant) { :progress_metadata }

        specify do
          action.humanized_output.must_equal "Processing metadata"
        end
      end
    end
  end

  class CloneDockerContentTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::CloneDockerContent }
    let(:source_repo) { katello_repositories(:redis) }
    let(:target_repo) { katello_repositories(:busybox) }

    it 'plans' do
      action = create_action action_class
      plan_action(action, source_repo, target_repo)
      assert_action_planed_with(action, ::Actions::Pulp::Repository::CopyDockerManifest,
                                source_pulp_id: source_repo.pulp_id,
                                target_pulp_id: target_repo.pulp_id)

      assert_action_planed_with(action, ::Actions::Pulp::Repository::CopyDockerTag,
                                source_pulp_id: source_repo.pulp_id,
                                target_pulp_id: target_repo.pulp_id)

      assert_action_planed_with(action, ::Actions::Katello::Repository::MetadataGenerate, target_repo)
    end
  end

  class CloneDockerContentEnvironmentTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::CloneToEnvironment }
    let(:source_repo) { katello_repositories(:redis) }

    it 'plans' do
      action = create_action action_class
      env = mock
      clone = mock
      action.expects(:find_or_build_environment_clone).returns(clone)
      clone.expects(:new_record?).returns(false)
      plan_action(action, source_repo, env)
      assert_action_planed_with(action, ::Actions::Katello::Repository::Clear, clone)
      assert_action_planed_with(action, ::Actions::Katello::Repository::CloneDockerContent, source_repo, clone)
    end
  end

  class CloneOstreeContentTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::CloneOstreeContent }
    let(:source_repo) { katello_repositories(:ostree) }
    let(:target_repo) { katello_repositories(:ostree_view1) }

    it 'plans' do
      action = create_action action_class
      plan_action(action, source_repo, target_repo)
      assert_action_planed_with(action, ::Actions::Pulp::Repository::CopyOstreeBranch,
                                source_pulp_id: source_repo.pulp_id,
                                target_pulp_id: target_repo.pulp_id)
      assert_action_planed_with(action, ::Actions::Katello::Repository::MetadataGenerate, target_repo)
      assert_action_planed_with(action, ::Actions::Katello::Repository::IndexContent, id: target_repo.id)
    end
  end

  class CloneOstreeContentEnvironmentTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::CloneToEnvironment }
    let(:source_repo) { katello_repositories(:ostree) }

    it 'plans' do
      action = create_action action_class
      env = mock
      clone = mock
      action.expects(:find_or_build_environment_clone).returns(clone)
      clone.expects(:new_record?).returns(false)
      plan_action(action, source_repo, env)
      assert_action_planed_with(action, ::Actions::Katello::Repository::Clear, clone)
      assert_action_planed_with(action, ::Actions::Katello::Repository::CloneOstreeContent, source_repo, clone)
    end
  end

  class CapsuleGenerateAndSyncTest < TestBase
    include Support::CapsuleSupport

    let(:action_class) { ::Actions::Katello::Repository::CapsuleGenerateAndSync }

    before do
      capsule_content.add_lifecycle_environment(repository.environment)
    end

    it 'plans' do
      plan_action(action, repository)
      assert_action_planed_with(action, ::Actions::Katello::CapsuleContent::Sync, capsule_content, :repository => repository)
    end
  end

  class ImportApplicabilityTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::ImportApplicability }

    it 'runs' do
      host =  FactoryGirl.build(:host, :id => 343)
      ::Katello::Repository.any_instance.stubs(:hosts_with_applicability).returns([host])
      Katello::EventQueue.expects(:push_event).with(::Katello::Events::ImportHostErrata::EVENT_TYPE, host.id)

      ForemanTasks.sync_task(action_class, :repo_id => repository.id, :contents_changed => true)
    end
  end

  class ExportRepositoryTest < TestBase
    let(:action_class) { ::Actions::Katello::Repository::Export }
    let(:repository) { katello_repositories(:rhel_6_x86_64) }

    it 'plans' do
      # required for export pre-run validation to succeed
      Setting['pulp_export_destination'] = '/tmp'

      action.stubs(:action_subject)
      plan_action(action, [repository], false, nil, 0, repository.pulp_id)

      # ensure arguments get transformed and bubble through to pulp actions.
      # Org label defaults to blank for this test, hence the group ID starts
      # with '-'.
      assert_action_planed_with(action, ::Actions::Pulp::RepositoryGroup::Create,
                                :id => "8",
                                :pulp_ids => [repository.pulp_id])
      assert_action_planed_with(action, ::Actions::Pulp::RepositoryGroup::Export) do |(inputs)|
        inputs[:id].must_equal "8"
        inputs[:export_to_iso].must_equal false
        # NB: the pulp export task writes to /v/l/p, not to a katello-owned dir
        inputs[:export_directory].must_include '/var/lib/pulp/published'
      end
      assert_action_planed_with(action, ::Actions::Pulp::RepositoryGroup::Delete,
                                :id => "8")
    end

    it 'plans without export destination' do
      action.stubs(:action_subject)

      assert_raises(Foreman::Exception) do
        plan_action(action, [repository], false, nil, 0, repository.pulp_id)
      end
    end

    it 'plans without writable destination' do
      Setting['pulp_export_destination'] = '/'
      action.stubs(:action_subject)

      assert_raises(Foreman::Exception) do
        plan_action(action, [repository], false, nil, 0, repository.pulp_id)
      end
    end
  end
end
