module ProxyAPI
  class PulpcoreReplicate < ::ProxyAPI::Resource
    def initialize(args)
      @url = args[:url] + "/pulpcore_replicate"
      super args
    end

    def replicate(payload)
      parse post(json_payload(payload), "replicate")
    rescue => e
      raise ::ProxyAPI::ProxyException.new(url, e, N_("Unable to replicate from upstream Pulp"))
    end

    def adopt(payload)
      parse post(json_payload(payload), "adopt")
    rescue => e
      raise ::ProxyAPI::ProxyException.new(url, e, N_("Unable to adopt existing Capsule Pulp objects for replication"))
    end

    private

    def json_payload(payload)
      payload.is_a?(String) ? payload : payload.to_json
    end
  end
end
