require 'smart_proxy_pulpcore_replicate/api'

map '/pulpcore_replicate' do
  run Proxy::PulpcoreReplicate::Api
end
