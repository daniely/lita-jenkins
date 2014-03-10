require "spec_helper"

describe Lita::Handlers::Jenkins, lita_handler: true do
  it { routes_command('jenkins list').to(:jenkins_list) }
  it { routes_command('jenkins list filter').to(:jenkins_list) }

  describe '#jenkins list' do
    let(:response) { double("Faraday::Response") }
    let(:api_response) { %{
      {"assignedLabels":[{}],"mode":"NORMAL","nodeDescription":"the master Jenkins node",
      "nodeName":"","numExecutors":4,"description":null,"jobs":[
      {"name":"chef_converge", "url":"http://test.com/job/chef_converge/","color":"disabled"},
      {"name":"deploy", "url":"http://test.com/job/deploy/","color":"red"},
      {"name":"build-all", "url":"http://test.com/job/build-all/","color":"blue"},
      {"name":"website", "url":"http://test.com/job/website/","color":"red"}],
      "overallLoad":{},
      "primaryView":{"name":"All","url":"http://test.com/"},"quietingDown":false,"slaveAgentPort":8090,"unlabeledLoad":{},
      "useCrumbs":false,"useSecurity":true,"views":[
      {"name":"All","url":"http://test.com/"},
      {"name":"Chef","url":"http://test.com/view/Chef/"},
      {"name":"Deploy","url":"http://test.com/view/Deploy/"},
      {"name":"Status","url":"http://test.com/view/Status/"},
      {"name":"deploy-pipeline","url":"http://test.com/view/deploy-pipeline/"}]}
    } }

    before do
      allow_any_instance_of(Faraday::Connection).to receive(:get).and_return(response)
    end

    it 'lists all jenkins jobs' do
      allow(response).to receive(:status).and_return(200)
      allow(response).to receive(:body).and_return(api_response)
      send_command('jenkins list')
      expect(replies.last).to eq("[1] DISA chef_converge\n[2] FAIL deploy\n[3] SUCC build-all\n[4] FAIL website\n")
    end

    it 'filters jobs' do
      allow(response).to receive(:status).and_return(200)
      allow(response).to receive(:body).and_return(api_response)
      send_command('jenkins list fail')
      expect(replies.last).to eq("[2] FAIL deploy\n[4] FAIL website\n")
    end

    it 'caches job list' do
      allow(response).to receive(:status).and_return(200)
      allow(response).to receive(:body).and_return(api_response)
      jenkins = Lita::Handlers::Jenkins.new
      expect(jenkins).to receive(:cache_job_list)

      send_command('jenkins list')
    end
  end
end
