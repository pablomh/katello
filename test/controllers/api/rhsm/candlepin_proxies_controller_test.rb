# encoding: utf-8

require "katello_test_helper"
require 'fact_importer_test_helper'

#rubocop:disable Metrics/ModuleLength
module Katello
  #rubocop:disable Metrics/BlockLength
  describe Api::Rhsm::CandlepinProxiesController do
    include Katello::AuthorizationSupportMethods
    include Support::ForemanTasks::Task

    before do
      setup_controller_defaults_api
      login_user(User.find(users(:admin).id))

      @content_facet_one = katello_content_facets(:content_facet_one)

      @organization = get_organization
      @host = FactoryBot.create(
        :host,
        :with_content,
        :with_subscription,
        :content_facet => @content_facet_one,
        :organization => @content_facet_one.single_content_view.organization
      )
      location = taxonomies(:location1)
      Setting[:default_location_subscribed_hosts] = location.title
      ::Katello::RegistrationManager.stubs(:check_registration_services).returns(true)
    end

    def build_proxy_response(body: '{"status":"ok"}', code: '200')
      net_response = stub(body: body, code: code)
      net_response.stubs(:each_header).multiple_yields(
        ['Content-Type', 'application/json'],
        ['X-Version', '4.3.1']
      )

      ::Katello::Resources::Candlepin::PooledTransport::Response.new(
        net_response,
        url: 'https://localhost:23443/candlepin/status'
      )
    end

    def stub_proxy_passthrough(path:, body: '')
      @controller.stubs(:authorize_proxy_routes).returns(true)
      @controller.stubs(:set_organization_id).returns(true)
      @controller.stubs(:check_media_type).returns(true)
      @controller.stubs(:add_candlepin_version_header).returns(true)
      @controller.instance_variable_set(:@request_path, path)
      @controller.instance_variable_set(:@request_body, StringIO.new(body))
      @controller.stubs(:proxy_request_path)
      @controller.stubs(:proxy_request_body)
    end

    describe "proxy pass-through actions" do
      it "filters pooled GET responses using the response body" do
        stub_proxy_passthrough(path: '/status')
        pooled_response = build_proxy_response
        modified_since = 'Wed, 01 Jan 2025 00:00:00 GMT'
        request.headers[Api::Rhsm::CandlepinProxiesController::IF_MODIFIED_SINCE_HEADER] = modified_since

        Resources::Candlepin::Proxy.expects(:get).with('/status', { 'If-Modified-Since' => modified_since }).returns(pooled_response)
        @controller.expects(:filter_sensitive_data).with(pooled_response.body).at_least_once.returns(pooled_response.body)

        process :get, method: :get

        assert_response 200
      end

      it "filters pooled POST responses using the response body" do
        request_body = '{"name":"override"}'
        stub_proxy_passthrough(path: '/consumers/uuid-1', body: request_body)
        pooled_response = build_proxy_response

        Resources::Candlepin::Proxy.expects(:post).with('/consumers/uuid-1', request_body, {}).returns(pooled_response)
        @controller.expects(:filter_sensitive_data).with(pooled_response.body).at_least_once.returns(pooled_response.body)

        process :post, method: :post

        assert_response 200
      end

      it "filters pooled PUT responses using the response body" do
        request_body = '{"serviceLevel":"Premium"}'
        stub_proxy_passthrough(path: '/consumers/uuid-1', body: request_body)
        pooled_response = build_proxy_response

        Resources::Candlepin::Proxy.expects(:put).with('/consumers/uuid-1', request_body, {}).returns(pooled_response)
        @controller.expects(:filter_sensitive_data).with(pooled_response.body).at_least_once.returns(pooled_response.body)

        process :put, method: :put, params: { id: 'uuid-1' }

        assert_response 200
      end

      it "filters pooled DELETE responses using the response body" do
        request_body = '[{"name":"enabled","value":null}]'
        stub_proxy_passthrough(path: '/consumers/uuid-1/content_overrides', body: request_body)
        pooled_response = build_proxy_response

        Resources::Candlepin::Proxy.expects(:delete).with('/consumers/uuid-1/content_overrides', request_body, {}).returns(pooled_response)
        @controller.expects(:filter_sensitive_data).with(pooled_response.body).at_least_once.returns(pooled_response.body)

        process :delete, method: :delete, params: { id: 'uuid-1' }

        assert_response 200
      end
    end

    describe "request context" do
      after do
        ::Logging.mdc.delete('request')
      end

      it "stores a forwarded correlation id in logging context" do
        request.headers[Api::Rhsm::CandlepinProxiesController::X_CORRELATION_ID_HEADER] = 'corr-123'

        @controller.send(:use_forwarded_correlation_id)

        assert_equal 'corr-123', ::Logging.mdc['request']
      end

      it "falls back to request id when no forwarded correlation id is present" do
        request.stubs(:request_id).returns('generated-req-id')

        @controller.send(:use_forwarded_correlation_id)

        assert_equal 'generated-req-id', ::Logging.mdc['request']
      end
    end

    describe "register with activation key should fail" do
      it "without specifying owner (organization)" do
        post('consumer_activate', params: { :activation_keys => 'non_existent_key' })
        assert_response 404
      end

      it "with unknown organization" do
        post('consumer_activate', params: { :owner => 'not_an_organization', :activation_keys => 'non_existent_key' })
        assert_response 404
      end

      it "with known organization and no activation_keys" do
        post('consumer_activate', params: { :owner => @organization.label, :activation_keys => '' })
        assert_response 400
      end
    end

    describe "register with activation key" do
      before do
        @facts = { 'network.hostname' => 'somehostname'}
        @activation_key = katello_activation_keys(:simple_key)
        ::Katello::RegistrationManager.stubs(:check_registration_services).returns(true)
      end

      it "should register" do
        Resources::Candlepin::Consumer.stubs(:get)

        ::Katello::RegistrationManager.expects(:process_registration).with({'facts' => @facts}, nil, [@activation_key]).returns(@host)

        post(:consumer_activate, params: { :organization_id => @activation_key.organization.label, :activation_keys => @activation_key.name, :facts => @facts })

        assert_response :success
      end

      it "de-duplicates provided activation key names" do
        Resources::Candlepin::Consumer.stubs(:get)

        ::Katello::RegistrationManager.expects(:process_registration).with({'facts' => @facts}, nil, [@activation_key]).returns(@host)

        key_names = "#{@activation_key.name},#{@activation_key.name}"

        post(:consumer_activate, params: { :organization_id => @activation_key.organization.label,
                                           :activation_keys => key_names, :facts => @facts })

        assert_response :success
      end

      it "should not register with dead services" do
        ::Katello::RegistrationManager.expects(:check_registration_services).returns(false)
        ::Katello::RegistrationManager.expects(:process_registration).never

        post(:consumer_activate, params: { :organization_id => @activation_key.organization.label,
                                           :activation_keys => @activation_key.name, :facts => @facts })

        assert_response 500
      end
    end

    describe "register with a lifecycle environment" do
      before do
        @facts = { 'network.hostname' => 'somehostname'}
        @content_view_environment = ContentViewEnvironment.find(katello_content_view_environments(:library_default_view_environment).id)
        ::Katello::RegistrationManager.stubs(:check_registration_services).returns(true)
      end

      it "should register" do
        ::Katello::RegistrationManager.expects(:check_registration_services).returns(true)
        Resources::Candlepin::Consumer.stubs(:get)
        ::Katello::RegistrationManager.expects(:process_registration).with({'facts' => @facts }, [@content_view_environment]).returns(@host)

        post(:consumer_create, params: { :organization_id => @content_view_environment.content_view.organization.label, :environment_id => @content_view_environment.cp_id, :facts => @facts })

        assert_response :success
      end

      it "should register with new environments param" do
        ::Katello::RegistrationManager.expects(:check_registration_services).returns(true)
        Resources::Candlepin::Consumer.stubs(:get)
        ::Katello::RegistrationManager.expects(:process_registration).with({'facts' => @facts }, [@content_view_environment]).returns(@host)

        post(:consumer_create, params: { :organization_id => @content_view_environment.content_view.organization.label, :environments => [{id: @content_view_environment.cp_id}], :facts => @facts })

        assert_response :success
      end

      it "should not register" do
        ::Katello::RegistrationManager.expects(:check_registration_services).returns(false)
        ::Katello::RegistrationManager.expects(:process_registration).never

        post(:consumer_create, params: { :organization_id => @content_view_environment.content_view.organization.label,
                                         :environment_id => @content_view_environment.cp_id, :facts => @facts })

        assert_response 500
      end

      it "should not register with multiple envs" do
        Setting[:allow_multiple_content_views] = false
        ::Katello::RegistrationManager.expects(:process_registration).never

        post(:consumer_create, params: { :organization_id => @content_view_environment.content_view.organization.label, :environments => [{id: @content_view_environment.cp_id}, {id: @content_view_environment.cp_id}], :facts => @facts })

        body = JSON.parse(response.body)

        assert_equal 'Registering to multiple environments is not enabled.', body['displayMessage']
        assert_response 400
      end
    end

    describe "update enabled_repos" do
      before do
        User.stubs(:consumer?).returns(true)
        uuid = @host.subscription_facet.uuid
        stub_cp_consumer_with_uuid(uuid)
      end
      let(:enabled_repos) do
        {
          "repos" => [
            {
              "baseurl" => ["https://hostname/pulp/content/foo"],
            },
            {
              "baseurl" => ["https://hostname/pulp/content/bar"],
            },
            {
              "baseurl" => ["https://hostname/pulp/content/bar"],
            },
            {
              "baseurl" => ["https://hostname/pulp/content/baz"],
            },
          ],
        }
      end

      it "should bind all" do
        Host::ContentFacet.any_instance.expects(:update_repositories_by_paths).with(
          [
            "/pulp/content/foo",
            "/pulp/content/bar",
            "/pulp/content/bar",
            "/pulp/content/baz",
          ])
        put :enabled_repos, params: { :id => @host.subscription_facet.uuid, :enabled_repos => enabled_repos }
        assert_equal 200, response.status
      end

      it "should fail with missing attribute 1" do
        put :enabled_repos, params: { :id => @host.subscription_facet.uuid }
        assert_equal 400, response.status
      end

      it "should fail with missing attribute 2" do
        put :enabled_repos, params: { :id => @host.subscription_facet.uuid, :enabled_repos => {} }
        assert_equal 400, response.status
      end

      it "should unbind all" do
        Host::ContentFacet.any_instance.expects(:update_repositories_by_paths).with([])
        put :enabled_repos, params: { :id => @host.subscription_facet.uuid, :enabled_repos => {"repos" => []}}
        assert_equal 200, response.status
      end

      it "should update facts" do
        facts = {'rhsm_fact' => 'rhsm_value'}
        ::Host.any_instance.expects(:update_candlepin_associations).with({ "facts" => facts })
        put :facts, params: { :id => @host.subscription_facet.uuid, :facts => facts }
        assert_equal 200, response.status
      end
    end

    describe "update facts with non-consumer user" do
      it "should prevent update facts for unauthorized user" do
        login_user(setup_user_with_permissions(:view_hosts, User.find(users(:restricted).id)))
        facts = {'rhsm_fact' => 'rhsm_value'}
        put :facts, params: { :id => @host.subscription_facet.uuid, :facts => facts }
        assert_response 403
      end

      it "should allow update facts for admin" do
        login_user(User.find(users(:admin).id))
        uuid = @host.subscription_facet.uuid
        stub_cp_consumer_with_uuid(uuid)
        facts = {'rhsm_fact' => 'rhsm_value'}
        ::Host.any_instance.expects(:update_candlepin_associations).with({ "facts" => facts })
        put :facts, params: { :id => @host.subscription_facet.uuid, :facts => facts}
        assert_response 200
      end
    end

    describe "list owners" do
      it 'should return organizations admin user is assigned to' do
        User.current = User.find(users(:admin).id)
        get :list_owners, params: { :login => User.current.login }

        assert_empty((JSON.parse(response.body).collect { |org| org['displayName'] } - Organization.pluck(:name)))
      end

      it 'should return organizations user is assigned to' do
        setup_current_user_with_permissions(:my_organizations)

        get :list_owners, params: { :login => User.current.login }
        assert_equal JSON.parse(response.body).first['displayName'], taxonomies(:empty_organization).name
      end

      it "should protect list owners with authentication" do
        get :list_owners, params: { :login => User.current.login }
        assert_response 200
      end

      it "should prevent listing owners for unauthenticated requests" do
        User.current = nil
        session[:user] = nil
        set_basic_auth('100', '100')
        get :list_owners, params: { :login => 100 }
        assert_response 401
      end
    end

    it "test_list_owners_protected" do
      assert_protected_action(:list_owners, :my_organizations) do
        get :list_owners, params: { :login => User.current.login }
      end
    end

    it "test_rhsm_index_protected" do
      assert_protected_action(:rhsm_index, :view_lifecycle_environments, [], [@organization]) do
        get :rhsm_index, params: { :organization_id => @organization.label }
      end
    end

    it "test_consumer_create_protected" do
      assert_protected_action(:consumer_create, [[:create_hosts,
                                                  :view_lifecycle_environments, :view_content_views]]) do
        post :consumer_create, params: { :environment_id => @organization.library.content_view_environments.first.cp_id }
      end
    end

    it "test_upload_tracer_profile_protected" do
      Resources::Candlepin::Consumer.stubs(:get)
      assert_protected_action(:upload_tracer_profile, :edit_hosts) do
        put :upload_tracer_profile, params: { :id => @host.subscription_facet.uuid }
      end
    end

    def test_regenerate_indentity_certificates
      consumer_stub = stub(:regenerate_identity_certificates => true)

      Candlepin::Consumer.expects(:new).with(@host.subscription_facet.uuid, @host.organization.label).returns(consumer_stub)
      Resources::Candlepin::Consumer.expects(:get).with(@host.subscription_facet.uuid)

      post :regenerate_identity_certificates, params: { :id => @host.subscription_facet.uuid }
    end

    it "test_regenerate_identity_certificates_protected" do
      Resources::Candlepin::Consumer.stubs(:get)
      assert_protected_action(:regenerate_identity_certificates, :edit_hosts) do
        post :regenerate_identity_certificates, params: { :id => @host.subscription_facet.uuid }
      end
    end

    describe "hypervisors_update" do
      it "hypervisors_update_with_no_owner" do
        post :hypervisors_update
        assert_response 403
      end

      it "hypervisors_update" do
        assert_sync_task(::Actions::Katello::Host::Hypervisors) do |params|
          assert_equal params, 'owner' => @organization.label, 'env' => nil
        end

        post(:hypervisors_update, :params => {:owner => @organization.label, :env => 'dev/dev'})
        assert_response 200
      end
    end

    describe "async_hypervisors_update" do
      it "hypervisors_update" do
        owner = @organization.label
        reporter_id = 100
        env = 'dev/dev'
        Katello::Resources::Candlepin::Consumer.expects(:async_hypervisors).returns('id' => 'foo').with do |params|
          assert_equal params[:owner], owner
          assert_equal params[:reporter_id], reporter_id
        end

        assert_async_task(::Actions::Katello::Host::Hypervisors) do |params, options|
          assert_nil params
          assert_equal options, :task_id => 'foo'
        end

        post(:async_hypervisors_update, :params => {owner: owner, reporter_id: reporter_id, env: env})
        assert_response 200
      end
    end

    describe "hypervisors_update_with_consumer_auth" do
      before do
        @controller.stubs(:client_authorized?).returns(true)
        @controller.stubs(:find_host).returns(@host)
        uuid = @host.subscription_facet.uuid
        User.stubs(:consumer?).returns(true)
        stub_cp_consumer_with_uuid(uuid)
      end

      it "hypervisors_update_correct_env_cv" do
        assert_sync_task(::Actions::Katello::Host::Hypervisors) do |params|
          assert_equal params, 'owner' => @host.organization.label, 'env' => nil
        end
        post :hypervisors_update
        assert_response 200
      end

      it "hypervisors_update_ignore_params" do
        assert_sync_task(::Actions::Katello::Host::Hypervisors) do |params|
          assert_equal params, 'owner' => @host.organization.label, 'env' => nil
        end
        post(:hypervisors_update, :params => {:owner => 'owner', :env => 'dev/dev'})
        assert_response 200
      end
    end

    describe "hypervisors_heartbeat" do
      it "sends the request to candlepin" do
        Katello::Resources::Candlepin::Consumer.expects(:hypervisors_heartbeat).with(owner: @organization.label, reporter_id: 123)

        put :hypervisors_heartbeat, params: { owner: @organization.label, reporter_id: 123 }

        assert_response 200
      end
    end

    describe "available releases" do
      it "can be listed by matching consumer" do
        # Stub out the current user to simulate consumer auth.
        uuid = @host.subscription_facet.uuid
        User.stubs(:consumer?).returns(true)
        stub_cp_consumer_with_uuid(uuid)
        get :available_releases, params: { :id => @host.subscription_facet.uuid }
        assert_response 200
      end

      it "forbidden with invalid consumer" do
        # Stub out the current user to simulate consumer auth.
        uuid = 4444
        User.stubs(:consumer?).returns(true)
        stub_cp_consumer_with_uuid(uuid)
        # Getting the available releases for a different consumer
        # should not be allowed.
        get :available_releases, params: { :id => @host.subscription_facet.uuid }
        assert_response 403
      end
    end

    describe "consumer destroy" do
      before do
        uuid = @host.subscription_facet.uuid
        User.stubs(:consumer?).returns(true)
        stub_cp_consumer_with_uuid(uuid)
        ::Katello::RegistrationManager.stubs(:check_registration_services).returns(true)
      end
      it "should unregister" do
        Setting[:unregister_delete_host] = false

        ::Katello::RegistrationManager.expects(:unregister_host).with(@host, :unregistering => true)
        delete :consumer_destroy, params: { :id => @host.subscription_facet.uuid }

        assert_response 204
      end

      it "should destroy the host if setting is set" do
        Setting[:unregister_delete_host] = true

        ::Katello::RegistrationManager.expects(:unregister_host).with(@host, :unregistering => false)
        delete :consumer_destroy, params: { :id => @host.subscription_facet.uuid }

        assert_response 204
      end

      it "should return Candlepin error when backend is down" do
        ::Katello::RegistrationManager.expects(:unregister_host).raises(RestClient::ServiceUnavailable.new(nil, 503))
        delete :consumer_destroy, params: { :id => @host.subscription_facet.uuid }
        assert_response 503
      end

      it "should not unregister when services are down" do
        ::Katello::RegistrationManager.expects(:check_registration_services).returns(false)
        ::Katello::RegistrationManager.expects(:unregister_host).never
        delete :consumer_destroy, params: { :id => @host.subscription_facet.uuid }
        assert_response 500
      end
    end

    describe "consumer show" do
      before do
        Resources::Candlepin::Consumer.stubs(:get).returns(Resources::Candlepin::Consumer.new(:id => 1, :uuid => 2))
      end

      it "can be accessed by user" do
        User.current = setup_user_with_permissions(:create_hosts, User.find(users(:restricted).id))
        get :consumer_show, params: { :id => @host.subscription_facet.uuid }
        assert_response 200
      end

      it "can be accessed by client" do
        uuid = @host.subscription_facet.uuid
        stub_cp_consumer_with_uuid(uuid)
        get :consumer_show, params: { :id => uuid }
        assert_response 200
      end
    end

    describe "consumer serials" do
      before do
        Resources::Candlepin::Consumer.stubs(:serials).returns([{'serial' => 'asdf'}])
      end

      it "can fetch serials" do
        uuid = @host.subscription_facet.uuid
        assert_nil @host.subscription_facet.last_checkin
        stub_cp_consumer_with_uuid(uuid)

        get :serials, params: { :id => uuid }
        assert_response 200
        refute_nil @host.subscription_facet.reload.last_checkin
      end
    end

    describe "consumer_facts" do
      include FactImporterIsolation

      it "can update the rhel lifecycle status" do
        allow_transactions_for_any_importer
        os = operatingsystems(:redhat)
        os.update!(major: "8", minor: "6")
        @host.update(:operatingsystem => os)
        uuid = @host.subscription_facet.uuid
        stub_cp_consumer_with_uuid(uuid)
        @controller.stubs(:update_host_registered_through)
        Katello::Resources::Candlepin::Consumer.stubs(:update)
        Katello::Resources::Candlepin::Consumer.stubs(:refresh_entitlements)
        Katello::Host::SubscriptionFacet.any_instance.stubs(:update_from_consumer_attributes)
        ::Host::Managed.any_instance.stubs(:refresh_global_status!)
        assert_equal ::Katello::RhelLifecycleStatus::UNKNOWN, @host.get_status(::Katello::RhelLifecycleStatus).status
        Date.expects(:today).returns(Date.new(2024, 5, 30))
        facts = {
          "distribution.id" => "Ootpa",
          "distribution::version" => "8.6",
          "distribution::name" => "Red Hat Enterprise Linux",
        }
        put :facts, params: { :id => uuid, :facts => facts }
        assert_response 200
        assert_equal ::Katello::RhelLifecycleStatus::FULL_SUPPORT, @host.reload.get_status(::Katello::RhelLifecycleStatus).status
      end
    end

    describe "server_status" do
      it "proxies Candlepin status and appends combined_reporting" do
        candlepin_response = { 'mode' => 'NORMAL', 'managerCapabilities' => [] }.with_indifferent_access
        Resources::Candlepin::CandlepinPing.stubs(:ping).returns(candlepin_response)

        get :server_status
        assert_response :success
        assert_includes JSON.parse(response.body)['managerCapabilities'], 'combined_reporting'
      end

      it "does not cache on Candlepin error" do
        Rails.cache.delete(::Katello::Resources::Candlepin::CandlepinPing::CACHE_KEY)
        Resources::Candlepin::CandlepinPing.stubs(:ping).raises(RestClient::ServiceUnavailable.new(nil, 503))

        2.times do
          get :server_status
          assert_response 503
        end

        assert_nil Rails.cache.read(::Katello::Resources::Candlepin::CandlepinPing::CACHE_KEY)
      end
    end

    describe "get parent host" do
      it "can get parent host" do
        capsule = "foocapsule.example.com"
        Setting[:foreman_url] = 'https://foreman.example.com'

        host_and_capsule = {"HTTP_X_FORWARDED_HOST" => "#{capsule}:8443, foo.example.com"}
        just_capsule = {"HTTP_X_FORWARDED_HOST" => "#{capsule}:8443"}
        nil_host = {}

        assert_equal @controller.get_parent_host(host_and_capsule), "#{capsule}"
        assert_equal @controller.get_parent_host(just_capsule), "#{capsule}"
        assert_equal 'foreman.example.com', @controller.get_parent_host(nil_host)
      end
    end

    describe "get content source id" do
      let(:hostname) { "content-source-test-#{SecureRandom.hex(8)}.example.com" }

      it "returns nil when no proxies match hostname" do
        result = @controller.get_content_source_id("nonexistent-#{SecureRandom.hex(8)}.example.com")
        assert_nil result
      end

      it "returns proxy id when single content proxy matches hostname" do
        pulp3_feature = Feature.find_or_create_by(:name => SmartProxy::PULP3_FEATURE)
        proxy = FactoryBot.create(:smart_proxy, :url => "https://#{hostname}:9090")
        proxy.features << pulp3_feature unless proxy.features.include?(pulp3_feature)

        result = @controller.get_content_source_id(hostname)
        assert_equal proxy.id, result
      end

      it "returns nil when no content proxies match hostname" do
        no_content_hostname = "no-content-#{SecureRandom.hex(8)}.example.com"
        proxy = FactoryBot.create(:smart_proxy, :url => "https://#{no_content_hostname}:9090")
        proxy.smart_proxy_features.where(
          :feature_id => Feature.where(:name => [SmartProxy::PULP_FEATURE, SmartProxy::PULP_NODE_FEATURE, SmartProxy::PULP3_FEATURE])
        ).destroy_all
        proxy.reload

        result = @controller.get_content_source_id(no_content_hostname)
        assert_nil result
      end

      it "returns content proxy id when multiple proxies match but only one has content features" do
        pulp3_feature = Feature.find_or_create_by(:name => SmartProxy::PULP3_FEATURE)
        content_proxy = FactoryBot.create(:smart_proxy, :url => "https://#{hostname}:9090")
        content_proxy.features << pulp3_feature unless content_proxy.features.include?(pulp3_feature)

        dev_feature = Feature.find_or_create_by(:name => "Development")
        non_content_proxy = FactoryBot.create(:smart_proxy, :url => "https://#{hostname}:9091")
        non_content_proxy.features << dev_feature unless non_content_proxy.features.include?(dev_feature)

        result = @controller.get_content_source_id(hostname)
        assert_equal content_proxy.id, result
      end

      it "returns lowest-id proxy when multiple content proxies match hostname" do
        pulp3_feature = Feature.find_or_create_by(:name => SmartProxy::PULP3_FEATURE)
        proxy1 = FactoryBot.create(:smart_proxy, :url => "https://#{hostname}:9090")
        proxy1.features << pulp3_feature unless proxy1.features.include?(pulp3_feature)

        proxy2 = FactoryBot.create(:smart_proxy, :url => "https://#{hostname}:9091")
        proxy2.features << pulp3_feature unless proxy2.features.include?(pulp3_feature)

        Rails.logger.expects(:warn).with(includes("Multiple content proxies found"))

        result = @controller.get_content_source_id(hostname)
        assert_equal proxy1.id, result
      end
    end
  end
end
