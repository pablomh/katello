module Katello
  module Pulp3
    module Replication
      class Request
        attr_reader :repository_ids, :force_sync, :prune, :remote_policy,
                    :protected_base_paths, :content_guard_href

        def initialize(repository_ids:, force_sync:, prune:, remote_policy: nil,
                       protected_base_paths: [], content_guard_href: nil)
          @repository_ids = Array(repository_ids).compact
          @force_sync = force_sync
          @prune = prune
          @remote_policy = remote_policy
          @protected_base_paths = Array(protected_base_paths).compact
          @content_guard_href = content_guard_href
        end

        def to_h
          {
            repository_ids: repository_ids,
            force_sync: force_sync,
            prune: prune,
            remote_policy: remote_policy,
            protected_base_paths: protected_base_paths,
            content_guard_href: content_guard_href,
          }
        end
      end
    end
  end
end
