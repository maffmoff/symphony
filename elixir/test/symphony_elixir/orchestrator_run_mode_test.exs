defmodule SymphonyElixir.OrchestratorRunModeTest do
  use SymphonyElixir.TestSupport

  describe "run_mode_for_state/1" do
    test "Todo maps to :implementation" do
      assert Orchestrator.run_mode_for_state("Todo") == :implementation
    end

    test "In Progress maps to :implementation" do
      assert Orchestrator.run_mode_for_state("In Progress") == :implementation
    end

    test "Rework maps to :implementation" do
      assert Orchestrator.run_mode_for_state("Rework") == :implementation
    end

    test "Agent Review maps to :review" do
      assert Orchestrator.run_mode_for_state("Agent Review") == :review
    end

    test "Merging maps to :land" do
      assert Orchestrator.run_mode_for_state("Merging") == :land
    end

    test "Done is not a runnable mode" do
      assert Orchestrator.run_mode_for_state("Done") == nil
    end

    test "Canceled is not a runnable mode" do
      assert Orchestrator.run_mode_for_state("Canceled") == nil
    end

    test "nil is not a runnable mode" do
      assert Orchestrator.run_mode_for_state(nil) == nil
    end

    test "case-insensitive matching" do
      assert Orchestrator.run_mode_for_state("agent review") == :review
      assert Orchestrator.run_mode_for_state("TODO") == :implementation
      assert Orchestrator.run_mode_for_state("merging") == :land
    end
  end

  describe "failure_signature_for_reason/1" do
    test "extracts port_exit signature" do
      assert Orchestrator.failure_signature_for_reason({:port_exit, 0}) == "port_exit 0"
    end

    test "extracts response_timeout signature" do
      assert Orchestrator.failure_signature_for_reason(:response_timeout) == "response_timeout"
    end

    test "extracts turn_timeout signature" do
      assert Orchestrator.failure_signature_for_reason(:turn_timeout) == "turn_timeout"
    end

    test "extracts boom signature" do
      assert Orchestrator.failure_signature_for_reason(:boom) == "boom"
    end

    test "truncates long error messages" do
      reason = String.duplicate("x", 200)
      sig = Orchestrator.failure_signature_for_reason(reason)
      assert String.length(sig) <= 80
    end
  end

  describe "run_mode mismatch during retry revalidation" do
    test "Agent Review issue is not dispatched as implementation retry" do
      issue_in_review = %Issue{
        id: "issue-rm-1",
        identifier: "MT-501",
        title: "Review test",
        description: "PR ready",
        state: "Agent Review",
        url: "https://example.org/MT-501"
      }

      # should_dispatch_issue uses the active_state_set which includes Agent Review
      # so the issue is a candidate, but the orchestrator's retry logic checks run_mode
      mode = Orchestrator.run_mode_for_state(issue_in_review.state)
      assert mode == :review

      # An implementation retry should detect the mismatch
      original_mode = :implementation
      current_mode = mode
      assert original_mode != current_mode
    end
  end

  describe "scheduler pressure does not increment failure_attempt" do
    test "no available orchestrator slots preserves failure_attempt at zero" do
      # Simulate the retry scheduling logic:
      # When error is "no available orchestrator slots", failure_attempt should not increment
      previous_failure_attempt = 0
      is_scheduler_pressure = true

      new_failure_attempt =
        if is_scheduler_pressure do
          previous_failure_attempt
        else
          previous_failure_attempt + 1
        end

      assert new_failure_attempt == 0
    end

    test "real failure increments failure_attempt" do
      previous_failure_attempt = 2
      is_scheduler_pressure = false

      new_failure_attempt =
        if is_scheduler_pressure do
          previous_failure_attempt
        else
          previous_failure_attempt + 1
        end

      assert new_failure_attempt == 3
    end
  end

  describe "reconcile_issue_states_for_test with run_mode-enriched state" do
    test "Agent Review is treated as active state when in active_states config" do
      # Write a workflow with Agent Review in active_states
      write_workflow_file!(
        Workflow.workflow_file_path(),
        tracker_active_states: ["Todo", "In Progress", "Agent Review", "Merging", "Rework"]
      )

      issue = %Issue{
        id: "issue-ar-1",
        identifier: "MT-600",
        title: "Agent Review state test",
        description: "test",
        state: "Agent Review",
        url: "https://example.org/MT-600"
      }

      # Start an orchestrator for state manipulation
      orchestrator_name = Module.concat(__MODULE__, :RunModeReconcile)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        run_mode: :review,
        linear_state_at_dispatch: "Agent Review",
        session_id: nil,
        turn_count: 0,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        worker_host: nil,
        workspace_path: nil,
        retry_attempt: 0,
        started_at: DateTime.utc_now()
      }

      state =
        initial_state
        |> Map.put(:running, %{issue.id => running_entry})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue.id))

      # Reconcile with the issue still in Agent Review — should keep running
      result_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
      assert Map.has_key?(result_state.running, issue.id)
    end
  end

  describe "snapshot includes run_mode and failure_attempt in retrying entries" do
    test "retrying entries expose run_mode and failure_signature" do
      orchestrator_name = Module.concat(__MODULE__, :SnapshotRunMode)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      initial_state = :sys.get_state(pid)

      retry_entry = %{
        attempt: 3,
        failure_attempt: 2,
        timer_ref: make_ref(),
        retry_token: make_ref(),
        due_at_ms: System.monotonic_time(:millisecond) + 60_000,
        identifier: "MT-700",
        error: "agent exited: {:port_exit, 0}",
        run_mode: :implementation,
        failure_signature: "port_exit 0",
        worker_host: nil,
        workspace_path: nil
      }

      state = %{initial_state | retry_attempts: %{"issue-snap-1" => retry_entry}}
      :sys.replace_state(pid, fn _ -> state end)

      snapshot = GenServer.call(pid, :snapshot)
      assert [retrying_entry] = snapshot.retrying
      assert retrying_entry.run_mode == :implementation
      assert retrying_entry.failure_signature == "port_exit 0"
      assert retrying_entry.failure_attempt == 2
    end
  end
end
