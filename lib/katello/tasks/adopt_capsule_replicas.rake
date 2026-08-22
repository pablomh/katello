namespace :katello do
  namespace :pulp do
    desc 'Label existing Capsule Pulp objects so policy=labeled replicate can adopt them (no wipe)'
    task :adopt_capsule_replicas => ['environment'] do
      User.current = User.anonymous_api_admin
      proxies = SmartProxy.unscoped.with_content.reject(&:pulp_primary?)
      if proxies.empty?
        puts _('No content Capsules found.')
        next
      end
      proxies.each do |proxy|
        puts _("Adopting Pulp objects on Capsule %{name}") % { name: proxy.name }
        begin
          outcomes = ::Katello::Pulp3::Replication::Adopt.new(proxy).call
          outcomes.each do |outcome|
            if outcome[:ok]
              puts _("  organization %{org}: adopted") % { org: outcome[:organization].name }
            else
              puts _("  organization %{org}: failed - %{error}") % { org: outcome[:organization].name, error: outcome[:error] }
            end
          end
        rescue StandardError => e
          puts _("  failed to adopt on %{name}: %{error}") % { name: proxy.name, error: e.message }
        end
      end
    end
  end
end
