defmodule SymphonyElixirWeb.RateLimitsDisplayTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.RateLimitsDisplay

  # Fixture derived from the real Codex 0.118.0 JSON-RPC wire format observed
  # via `/api/v1/state` after the camelCase extractor fix. Note that `planType`
  # is present on the wire even though it is NOT a declared field of
  # `RateLimitSnapshot.ts` (ts-rs declaration drift), which is exactly why the
  # renderer must surface extras instead of assuming a fixed shape.
  @real_codex_payload %{
    "credits" => nil,
    "limitId" => "codex",
    "limitName" => nil,
    "planType" => "pro",
    "primary" => %{
      "resetsAt" => 1_775_884_663,
      "usedPercent" => 4.0,
      "windowDurationMins" => 300
    },
    "secondary" => %{
      "resetsAt" => 1_776_364_063,
      "usedPercent" => 35.0,
      "windowDurationMins" => 10_080
    }
  }

  # Fixed reference `now` slightly before the primary resetsAt so that
  # relative-time assertions are deterministic and reset is in the future.
  @reference_now DateTime.from_unix!(1_775_884_663 - 7623)

  describe "codex_shape?/1" do
    test "accepts real camelCase payload" do
      assert RateLimitsDisplay.codex_shape?(@real_codex_payload)
    end

    test "accepts legacy snake_case payload" do
      legacy = %{
        "limit_id" => "codex",
        "primary" => %{"used_percent" => 1.0, "window_minutes" => 300, "resets_at" => 1}
      }

      assert RateLimitsDisplay.codex_shape?(legacy)
    end

    test "rejects empty map" do
      refute RateLimitsDisplay.codex_shape?(%{})
    end

    test "rejects map with only limitId and no buckets" do
      refute RateLimitsDisplay.codex_shape?(%{"limitId" => "codex"})
    end

    test "rejects map with buckets but no limitId" do
      refute RateLimitsDisplay.codex_shape?(%{"primary" => %{"usedPercent" => 1}})
    end

    test "accepts atom-keyed map" do
      assert RateLimitsDisplay.codex_shape?(%{limitId: "codex", primary: %{usedPercent: 1}})
    end

    test "rejects nil" do
      refute RateLimitsDisplay.codex_shape?(nil)
    end

    test "rejects string" do
      refute RateLimitsDisplay.codex_shape?("not a map")
    end
  end

  describe "label/1" do
    test "prefers limitName over limitId when both present" do
      assert RateLimitsDisplay.label(%{"limitName" => "Codex Pro", "limitId" => "codex"}) ==
               "Codex Pro"
    end

    test "falls back to limitId when limitName is nil" do
      assert RateLimitsDisplay.label(%{"limitName" => nil, "limitId" => "codex"}) == "codex"
    end

    test "falls back to snake_case limit_name" do
      assert RateLimitsDisplay.label(%{"limit_name" => "Legacy Name"}) == "Legacy Name"
    end

    test "falls back to snake_case limit_id" do
      assert RateLimitsDisplay.label(%{"limit_id" => "legacy_codex"}) == "legacy_codex"
    end

    test "returns unknown when no identifier is present" do
      assert RateLimitsDisplay.label(%{}) == "unknown"
    end

    test "returns unknown for nil" do
      assert RateLimitsDisplay.label(nil) == "unknown"
    end
  end

  describe "plan/1" do
    test "extracts camelCase planType" do
      assert RateLimitsDisplay.plan(@real_codex_payload) == "pro"
    end

    test "extracts snake_case plan_type" do
      assert RateLimitsDisplay.plan(%{"plan_type" => "team"}) == "team"
    end

    test "returns nil when absent" do
      assert RateLimitsDisplay.plan(%{"limitId" => "codex"}) == nil
    end

    test "returns nil for empty string" do
      assert RateLimitsDisplay.plan(%{"planType" => ""}) == nil
    end

    test "returns nil for nil input" do
      assert RateLimitsDisplay.plan(nil) == nil
    end
  end

  describe "buckets/2" do
    test "builds primary and secondary buckets from real payload" do
      buckets = RateLimitsDisplay.buckets(@real_codex_payload, @reference_now)

      assert [primary, secondary] = buckets

      assert primary.title == "Primary"
      assert primary.used == "4%"
      assert primary.window == "5h"
      assert primary.resets_absolute == "2026-04-11T05:17:43Z"
      assert primary.resets_relative == "in 2h 7m"

      assert secondary.title == "Secondary"
      assert secondary.used == "35%"
      assert secondary.window == "7d"
      assert String.starts_with?(secondary.resets_absolute, "2026-04-")
      assert String.starts_with?(secondary.resets_relative, "in ")
    end

    test "handles legacy snake_case buckets" do
      legacy = %{
        "limit_id" => "codex",
        "primary" => %{
          "used_percent" => 12.5,
          "window_minutes" => 60,
          "resets_at" => 1_775_884_663
        }
      }

      assert [primary] = RateLimitsDisplay.buckets(legacy, @reference_now)
      assert primary.title == "Primary"
      assert primary.used == "12.5%"
      assert primary.window == "1h"
    end

    test "emits em dash for missing fields" do
      sparse = %{"limitId" => "x", "primary" => %{}}
      assert [primary] = RateLimitsDisplay.buckets(sparse, @reference_now)
      assert primary.used == "—"
      assert primary.window == "—"
      assert primary.resets_relative == "—"
      assert primary.resets_absolute == "—"
    end

    test "skips non-map bucket values" do
      assert RateLimitsDisplay.buckets(%{"primary" => nil, "secondary" => "weird"}, @reference_now) ==
               []
    end

    test "returns empty list for non-map input" do
      assert RateLimitsDisplay.buckets(nil, @reference_now) == []
    end
  end

  describe "credits/1" do
    test "returns nil when credits is nil" do
      assert RateLimitsDisplay.credits(@real_codex_payload) == nil
    end

    test "returns unlimited for unlimited credits" do
      assert RateLimitsDisplay.credits(%{"credits" => %{"unlimited" => true}}) == "unlimited"
    end

    test "returns formatted balance when has_credits with numeric balance" do
      assert RateLimitsDisplay.credits(%{
               "credits" => %{"has_credits" => true, "balance" => 1_234_567}
             }) == "1,234,567"
    end

    test "returns available when has_credits without balance" do
      assert RateLimitsDisplay.credits(%{"credits" => %{"has_credits" => true}}) == "available"
    end

    test "returns none when has_credits is false" do
      assert RateLimitsDisplay.credits(%{"credits" => %{"has_credits" => false}}) == "none"
    end

    test "accepts camelCase hasCredits" do
      assert RateLimitsDisplay.credits(%{"credits" => %{"hasCredits" => true, "balance" => 50}}) ==
               "50"
    end
  end

  describe "extras/2" do
    test "real payload has no extras (all fields are known)" do
      # `planType` is in the known-keys set because it's consumed by plan/1
      # for the summary line, so it should not appear as an extra entry.
      assert RateLimitsDisplay.extras(@real_codex_payload, @reference_now) == []
    end

    test "returns empty list when only known keys are present" do
      only_known = Map.delete(@real_codex_payload, "planType")
      assert RateLimitsDisplay.extras(only_known, @reference_now) == []
    end

    test "includes unknown keys sorted by humanized name" do
      payload =
        @real_codex_payload
        |> Map.put("foo", 42)
        |> Map.put("barBaz", "hello")

      extras = RateLimitsDisplay.extras(payload, @reference_now)
      assert [{"bar baz", "hello"}, {"foo", "42"}] = extras
    end

    test "formats unix timestamp extras with smart formatter" do
      payload = Map.put(@real_codex_payload, "checkpointAt", 1_775_884_663)
      extras = RateLimitsDisplay.extras(payload, @reference_now)

      assert Enum.any?(extras, fn {k, v} ->
               k == "checkpoint at" and String.contains?(v, "in ")
             end)
    end
  end

  describe "flatten/2" do
    test "flattens nested map with dot-path keys" do
      payload = %{"outer" => %{"inner" => %{"leaf" => 123}}}
      assert RateLimitsDisplay.flatten(payload, @reference_now) == [{"outer / inner / leaf", "123"}]
    end

    test "flattens real codex payload into path entries" do
      flat = RateLimitsDisplay.flatten(@real_codex_payload, @reference_now)
      keys = Enum.map(flat, fn {k, _} -> k end)

      assert "credits" in keys
      assert "limitId" in keys
      assert "primary / usedPercent" in keys
      assert "primary / windowDurationMins" in keys
      assert "primary / resetsAt" in keys
      assert "secondary / usedPercent" in keys
    end

    test "formats leaf values smartly" do
      flat = RateLimitsDisplay.flatten(@real_codex_payload, @reference_now)
      map = Map.new(flat)

      assert map["primary / usedPercent"] == "4%"
      assert map["primary / windowDurationMins"] == "5h"
      assert String.contains?(map["primary / resetsAt"], "(in ")
    end

    test "renders nil as em dash" do
      assert RateLimitsDisplay.flatten(%{"k" => nil}, @reference_now) == [{"k", "—"}]
    end

    test "renders empty nested map as empty-brace marker" do
      assert RateLimitsDisplay.flatten(%{"empty" => %{}}, @reference_now) ==
               [{"empty", "{}"}]
    end

    test "returns sorted output" do
      payload = %{"z" => 1, "a" => 2, "m" => 3}

      assert RateLimitsDisplay.flatten(payload, @reference_now) ==
               [{"a", "2"}, {"m", "3"}, {"z", "1"}]
    end
  end

  describe "format_percent/1" do
    test "integer with percent suffix" do
      assert RateLimitsDisplay.format_percent(4) == "4%"
    end

    test "whole float collapses to integer display" do
      assert RateLimitsDisplay.format_percent(4.0) == "4%"
    end

    test "fractional float keeps decimals" do
      assert RateLimitsDisplay.format_percent(4.5) == "4.5%"
    end

    test "returns nil for nil" do
      assert RateLimitsDisplay.format_percent(nil) == nil
    end

    test "returns nil for non-number" do
      assert RateLimitsDisplay.format_percent("4") == nil
    end
  end

  describe "format_window_minutes/1" do
    test "5 hours" do
      assert RateLimitsDisplay.format_window_minutes(300) == "5h"
    end

    test "7 days" do
      assert RateLimitsDisplay.format_window_minutes(10_080) == "7d"
    end

    test "hour and minutes mix" do
      assert RateLimitsDisplay.format_window_minutes(90) == "1h 30m"
    end

    test "sub-hour in minutes" do
      assert RateLimitsDisplay.format_window_minutes(45) == "45m"
    end

    test "single hour" do
      assert RateLimitsDisplay.format_window_minutes(60) == "1h"
    end

    test "returns nil for zero" do
      assert RateLimitsDisplay.format_window_minutes(0) == nil
    end

    test "returns nil for nil" do
      assert RateLimitsDisplay.format_window_minutes(nil) == nil
    end

    test "returns nil for float" do
      assert RateLimitsDisplay.format_window_minutes(300.0) == nil
    end
  end

  describe "format_unix_epoch/2" do
    test "future epoch returns absolute + relative" do
      result = RateLimitsDisplay.format_unix_epoch(1_775_884_663, @reference_now)
      assert result.absolute == "2026-04-11T05:17:43Z"
      assert result.relative == "in 2h 7m"
    end

    test "past epoch returns reset ready" do
      past = DateTime.to_unix(DateTime.add(@reference_now, -3600, :second))
      result = RateLimitsDisplay.format_unix_epoch(past, @reference_now)
      assert result.relative == "reset ready"
    end

    test "epoch within seconds" do
      soon = DateTime.to_unix(DateTime.add(@reference_now, 30, :second))
      result = RateLimitsDisplay.format_unix_epoch(soon, @reference_now)
      assert result.relative == "in 30s"
    end

    test "range-below-floor is rejected" do
      assert RateLimitsDisplay.format_unix_epoch(300, @reference_now) == nil
    end

    test "range-above-ceiling is rejected" do
      assert RateLimitsDisplay.format_unix_epoch(5_000_000_000, @reference_now) == nil
    end

    test "non-integer is rejected" do
      assert RateLimitsDisplay.format_unix_epoch(1_775_884_663.5, @reference_now) == nil
    end

    test "nil is rejected" do
      assert RateLimitsDisplay.format_unix_epoch(nil, @reference_now) == nil
    end
  end

  describe "format_value/3" do
    test "nil renders as em dash" do
      assert RateLimitsDisplay.format_value("anything", nil, @reference_now) == "—"
    end

    test "usedPercent key is formatted as percent" do
      assert RateLimitsDisplay.format_value("usedPercent", 4.0, @reference_now) == "4%"
    end

    test "used_percent snake_case key is formatted as percent" do
      assert RateLimitsDisplay.format_value("used_percent", 4, @reference_now) == "4%"
    end

    test "windowDurationMins key is formatted as window" do
      assert RateLimitsDisplay.format_value("windowDurationMins", 300, @reference_now) == "5h"
    end

    test "window_minutes snake_case key is formatted as window" do
      assert RateLimitsDisplay.format_value("window_minutes", 60, @reference_now) == "1h"
    end

    test "resetsAt key is formatted as timestamp" do
      value = RateLimitsDisplay.format_value("resetsAt", 1_775_884_663, @reference_now)
      assert String.contains?(value, "2026-04-11T05:17:43Z")
      assert String.contains?(value, "in ")
    end

    test "resets_at snake_case key is formatted as timestamp" do
      value = RateLimitsDisplay.format_value("resets_at", 1_775_884_663, @reference_now)
      assert String.contains?(value, "2026-04-11")
    end

    test "unknown string is passed through" do
      assert RateLimitsDisplay.format_value("limitId", "codex", @reference_now) == "codex"
    end

    test "unknown integer is stringified" do
      assert RateLimitsDisplay.format_value("count", 42, @reference_now) == "42"
    end

    test "boolean is stringified" do
      assert RateLimitsDisplay.format_value("flag", true, @reference_now) == "true"
    end

    test "nested map is summarized with field count" do
      assert RateLimitsDisplay.format_value("nested", %{"a" => 1, "b" => 2}, @reference_now) ==
               "2 fields"
    end
  end
end
