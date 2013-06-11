require "spec_helper"

module HealthManager
  describe Harmonizer do
    let(:nudger) { mock.as_null_object }
    let(:droplet_registry) { mock.as_null_object }
    let(:desired_state) { mock.as_null_object }
    let(:actual_state) { mock.as_null_object }
    let(:scheduler) { mock.as_null_object }
    let(:varz) { mock.as_null_object }
    let(:app) do
      app, _ = make_app(:num_instances => 1)
      heartbeats = make_heartbeat([app], :app_live_version => "version-1")
      app.process_heartbeat(heartbeats["droplets"][0])
      heartbeats = make_heartbeat([app], :app_live_version => "version-2")
      app.process_heartbeat(heartbeats["droplets"][0])
      app
    end

    subject do
      Harmonizer.new({
        :health_manager_component_registry => {:nudger => nudger},
      }, varz, nudger, scheduler, actual_state, desired_state, droplet_registry)
    end

    describe "#prepare" do
      let(:droplet) do
        droplet = Droplet.new("app-id")
        droplet.stub(:get_instance) do |ind|
          instances = [
            {"state" => "FLAPPING"},
            {"state" => "RUNNING"}
          ]
          instances[ind]
        end
        droplet
      end

      describe "listeners" do
        before { subject.prepare }
        after { Droplet.remove_all_listeners }

        describe "on missing instances" do
          context "when desired state update is required" do
            before { droplet.desired_state_update_required = false }

            context "when instance is flapping" do
              it "executes flapping policy" do
                subject.should_receive(:execute_flapping_policy).with(droplet, 0, {"state" => "FLAPPING"}, false)
                Droplet.notify_listener(:missing_instances, droplet, [0])
              end
            end

            context "when instance is NOT flapping" do
              it "executes NOT flapping policy" do
                nudger.should_receive(:start_instance).with(droplet, 1, NORMAL_PRIORITY)
                Droplet.notify_listener(:missing_instances, droplet, [1])
              end
            end
          end
        end

        describe "on extra_instances" do
          context "when desired state update is required" do
            before { droplet.desired_state_update_required = false }

            it "stops instances immediately" do
              nudger.should_receive(:stop_instances_immediately).with(droplet, [1, 2])
              Droplet.notify_listener(:extra_instances, droplet, [1, 2])
            end
          end
        end

        describe "on exit dea" do
          it "starts instance with high priority" do
            nudger.should_receive(:start_instance).with(droplet, 5, HIGH_PRIORITY)
            Droplet.notify_listener(:exit_dea, droplet, {"index" => 5})
          end
        end

        describe "on exit_crashed" do
          context "when instance is flapping" do
            it "executes flapping policy" do
              subject.should_receive(:execute_flapping_policy).with(droplet, 0, {"state" => "FLAPPING"}, true)
              Droplet.notify_listener(:exit_crashed, droplet, {"version" => 0, "index" => 0})
            end
          end

          context "when instance is NOT flapping" do
            it "executes NOT flapping policy" do
              nudger.should_receive(:start_instance).with(droplet, 1, LOW_PRIORITY)
              Droplet.notify_listener(:exit_crashed, droplet, {"version" => 1, "index" => 1})
            end
          end
        end

        describe "on droplet update" do
          def test_listener
            Droplet.notify_listener(:droplet_updated, droplet)
          end

          it "aborts all_pending_delayed_restarts" do
            subject.should_receive(:abort_all_pending_delayed_restarts).with(droplet)
            test_listener
          end

          it "updates desired state" do
            subject.should_receive(:update_desired_state)
            test_listener
          end

          it "sets desired_state_update_required" do
            droplet.should_receive(:desired_state_update_required=).with(true)
            test_listener
          end
        end
      end
    end

    describe "when app is considered to be an extra app" do
      it "stops all instances of the app" do
        nudger
          .should_receive(:stop_instances_immediately)
          .with(app, [
            ["version-1-0", "Extra app"],
            ["version-2-0", "Extra app"]
          ])
        desired_state.stub(:available?) { true }

        subject.on_extra_app(app)
      end

      context "when the desired state provider is unavailable" do
        before do
          desired_state.stub(:available?) { false }
        end

        it 'should not stop anything' do
          nudger.should_not_receive(:stop_instances_immediately)
          subject.on_extra_app(app)
        end
      end
    end
  end
end
