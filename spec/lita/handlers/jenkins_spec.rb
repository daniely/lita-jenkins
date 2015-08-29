require "spec_helper"

describe Lita::Handlers::Jenkins, lita_handler: true do
  describe 'lita routes' do
    it { is_expected.to route_command('jenkins list').to(:jenkins_list) }
    it { is_expected.to route_command('jenkins list filter').to(:jenkins_list) }
    it { is_expected.to route_command('jenkins build 2').to(:jenkins_build) }
    it { is_expected.to route_command('jenkins build deploy').to(:jenkins_build) }
    it { is_expected.to route_command('jenkins build deploy, PARAM=value').to(:jenkins_build) }
  end

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
    allow_any_instance_of(Faraday::Connection).to receive(:post).and_return(response)
  end

  describe '#headers' do
    it 'returns empty auth headers correctly by default' do
      return_value = described_class.new(robot).headers
      expect(return_value.inspect).to eq("{}")
    end

    it 'encodes auth headers correctly' do
      registry.config.handlers.jenkins.auth = "foo:bar"
      return_value = described_class.new(robot).headers
      expect(return_value.inspect).to eq("{\"Authorization\"=>\"Basic Zm9vOmJhcg==\"}")
    end
  end

  describe '#jenkins list' do
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
  end

  describe '#jenkins build' do
    it 'build job id' do
      allow(response).to receive(:status).and_return(201)
      allow(response).to receive(:body).and_return(api_response)
      send_command('jenkins b 2')
      expect(replies.last).to eq("(201) Build started for deploy /job/deploy")
    end

    it 'build job name' do
      allow(response).to receive(:status).and_return(201)
      allow(response).to receive(:body).and_return(api_response)
      send_command('jenkins b deploy')
      expect(replies.last).to eq("(201) Build started for deploy /job/deploy")
    end

    it 'build job underscored name' do
      allow(response).to receive(:status).and_return(201)
      allow(response).to receive(:body).and_return(api_response)
      send_command('jenkins b chef_converge')
      expect(replies.last).to eq("(201) Build started for chef_converge /job/chef_converge")
    end

    it 'build job hyphenated name' do
      allow(response).to receive(:status).and_return(201)
      allow(response).to receive(:body).and_return(api_response)
      send_command('jenkins b build-all')
      expect(replies.last).to eq("(201) Build started for build-all /job/build-all")
    end

    it 'build job bad id' do
      allow(response).to receive(:status).and_return(201)
      allow(response).to receive(:body).and_return(api_response)
      send_command('jenkins b 99')
      expect(replies.last).to eq("I couldn't find that job. Try `jenkins list` to get a list.")
    end

    it 'build job bad name' do
      allow(response).to receive(:status).and_return(201)
      allow(response).to receive(:body).and_return(api_response)
      send_command('jenkins b sloppyjob')
      expect(replies.last).to eq("I couldn't find that job. Try `jenkins list` to get a list.")
    end

    it 'build job error 500 response' do
      allow(response).to receive(:status).and_return(500)
      allow(response).to receive(:body).and_return(api_response)
      send_command('jenkins b 2')
      expect(replies.last).to eq(api_response)
    end

    context 'paramterized builds' do
      describe 'job with param' do
        it 'builds job id' do
          allow(response).to receive(:status).and_return(201)
          allow(response).to receive(:body).and_return(api_response)
          send_command('jenkins b 2, PARAM=value')
          expect(replies.last).to eq("(201) Build started for deploy /job/deploy, Params: 'PARAM=value'")
        end

        it 'builds job name' do
          allow(response).to receive(:status).and_return(201)
          allow(response).to receive(:body).and_return(api_response)
          send_command('jenkins b deploy, PARAM=value')
          expect(replies.last).to eq("(201) Build started for deploy /job/deploy, Params: 'PARAM=value'")
        end
      end
    end
  end
end
