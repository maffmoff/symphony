defmodule SymphonyElixirWeb.RateLimitsDisplay do
  @moduledoc false

  # Presentation helpers for the opaque `rate_limits` payload that Symphony
  # stores from agent updates (see Symphony SPEC.md §13.5: "Any human-readable
  # presentation of rate-limit data is implementation-defined.").
  #
  # The renderer is schema-aware of the current Codex 0.118.0 RateLimitSnapshot
  # wire format (`limitId` + `primary`/`secondary`/`credits`) but never depends
  # on it being exactly that shape — unknown or future fields fall through to a
  # generic flattened key/value rendering so schema drift cannot hide data.

  @known_keys ~w(
    limitId limit_id
    limitName limit_name
    primary secondary
    credits
    planType plan_type
  )

  @unix_epoch_floor 1_500_000_000
  @unix_epoch_ceil 3_000_000_000

  @em_dash "—"

  # ---------------------------------------------------------------------------
  # Public API (all @doc false — not part of external documentation)
  # ---------------------------------------------------------------------------

  @doc false
  @spec codex_shape?(term()) :: boolean()
  def codex_shape?(rate_limits) when is_map(rate_limits) do
    has_limit_id =
      not is_nil(map_get_any(rate_limits, ["limitId", :limitId, "limit_id", :limit_id]))

    has_bucket =
      is_map(map_get_any(rate_limits, ["primary", :primary])) or
        is_map(map_get_any(rate_limits, ["secondary", :secondary]))

    has_limit_id and has_bucket
  end

  def codex_shape?(_), do: false

  @doc false
  @spec label(map()) :: String.t()
  def label(rate_limits) when is_map(rate_limits) do
    case first_non_nil(rate_limits, [
           "limitName",
           :limitName,
           "limit_name",
           :limit_name,
           "limitId",
           :limitId,
           "limit_id",
           :limit_id
         ]) do
      nil -> "unknown"
      value -> to_string(value)
    end
  end

  def label(_), do: "unknown"

  @doc false
  @spec plan(map()) :: String.t() | nil
  def plan(rate_limits) when is_map(rate_limits) do
    case first_non_nil(rate_limits, ["planType", :planType, "plan_type", :plan_type]) do
      nil -> nil
      "" -> nil
      value -> to_string(value)
    end
  end

  def plan(_), do: nil

  @doc false
  @spec buckets(map(), DateTime.t()) :: [map()]
  def buckets(rate_limits, %DateTime{} = now) when is_map(rate_limits) do
    [{"Primary", ["primary", :primary]}, {"Secondary", ["secondary", :secondary]}]
    |> Enum.flat_map(fn {title, keys} ->
      case map_get_any(rate_limits, keys) do
        bucket when is_map(bucket) -> [build_bucket(title, bucket, now)]
        _ -> []
      end
    end)
  end

  def buckets(_, _), do: []

  @doc false
  @spec credits(map()) :: String.t() | nil
  def credits(rate_limits) when is_map(rate_limits) do
    case map_get_any(rate_limits, ["credits", :credits]) do
      nil ->
        nil

      credits when is_map(credits) ->
        summarize_credits(credits)

      other ->
        to_string(other)
    end
  end

  def credits(_), do: nil

  @doc false
  @spec extras(map(), DateTime.t()) :: [{String.t(), String.t()}]
  def extras(rate_limits, %DateTime{} = now) when is_map(rate_limits) do
    rate_limits
    |> Enum.reject(fn {k, _} -> to_string(k) in @known_keys end)
    |> Enum.map(fn {k, v} -> {humanize_key(k), format_value(to_string(k), v, now)} end)
    |> Enum.sort_by(fn {key, _} -> key end)
  end

  def extras(_, _), do: []

  @doc false
  @spec flatten(map(), DateTime.t()) :: [{String.t(), String.t()}]
  def flatten(rate_limits, %DateTime{} = now) when is_map(rate_limits) do
    rate_limits
    |> do_flatten(now, [])
    |> Enum.sort_by(fn {path, _} -> path end)
  end

  def flatten(_, _), do: []

  @doc false
  @spec format_percent(term()) :: String.t() | nil
  def format_percent(value) when is_integer(value), do: "#{value}%"

  def format_percent(value) when is_float(value) do
    if value == Float.round(value) do
      "#{trunc(value)}%"
    else
      "#{value}%"
    end
  end

  def format_percent(_), do: nil

  @doc false
  @spec format_window_minutes(term()) :: String.t() | nil
  def format_window_minutes(value) when is_integer(value) and value > 0 do
    cond do
      rem(value, 1440) == 0 -> "#{div(value, 1440)}d"
      rem(value, 60) == 0 -> "#{div(value, 60)}h"
      value >= 60 -> "#{div(value, 60)}h #{rem(value, 60)}m"
      true -> "#{value}m"
    end
  end

  def format_window_minutes(_), do: nil

  @doc false
  @spec format_unix_epoch(term(), DateTime.t()) ::
          %{absolute: String.t(), relative: String.t()} | nil
  def format_unix_epoch(value, %DateTime{} = now)
      when is_integer(value) and value >= @unix_epoch_floor and value <= @unix_epoch_ceil do
    case DateTime.from_unix(value) do
      {:ok, dt} ->
        absolute = dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        diff_seconds = DateTime.diff(dt, now, :second)
        %{absolute: absolute, relative: relative_reset(diff_seconds)}

      _ ->
        nil
    end
  end

  def format_unix_epoch(_, _), do: nil

  @doc false
  @spec format_value(String.t(), term(), DateTime.t()) :: String.t()
  def format_value(_key, nil, _now), do: @em_dash

  def format_value(key, value, %DateTime{} = now) do
    cond do
      percent_key?(key) and is_number(value) ->
        format_percent(value) || to_string(value)

      minutes_key?(key) and is_integer(value) ->
        format_window_minutes(value) || to_string(value)

      timestamp_key?(key) and is_integer(value) ->
        case format_unix_epoch(value, now) do
          nil -> Integer.to_string(value)
          %{absolute: abs, relative: rel} -> "#{abs} (#{rel})"
        end

      is_integer(value) ->
        Integer.to_string(value)

      is_float(value) ->
        Float.to_string(value)

      is_boolean(value) ->
        to_string(value)

      is_binary(value) ->
        value

      is_atom(value) ->
        Atom.to_string(value)

      is_map(value) ->
        # Non-recursive summary for extras/unknown callers. Callers that want
        # full nested rendering should use `flatten/2` instead.
        "#{map_size(value)} fields"

      is_list(value) ->
        "#{length(value)} items"

      true ->
        inspect(value, limit: 5)
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp build_bucket(title, bucket, now) do
    used_percent =
      map_get_any(bucket, ["usedPercent", :usedPercent, "used_percent", :used_percent])

    window_mins =
      map_get_any(bucket, [
        "windowDurationMins",
        :windowDurationMins,
        "window_duration_mins",
        :window_duration_mins,
        "windowMinutes",
        :windowMinutes,
        "window_minutes",
        :window_minutes
      ])

    resets_at =
      map_get_any(bucket, ["resetsAt", :resetsAt, "resets_at", :resets_at])

    reset_info =
      case resets_at do
        n when is_integer(n) -> format_unix_epoch(n, now)
        _ -> nil
      end

    %{
      title: title,
      used: format_percent(used_percent) || @em_dash,
      window: format_window_minutes(window_mins) || @em_dash,
      resets_relative: (reset_info && reset_info.relative) || @em_dash,
      resets_absolute: (reset_info && reset_info.absolute) || @em_dash
    }
  end

  defp summarize_credits(credits) do
    unlimited = map_get_any(credits, ["unlimited", :unlimited]) == true

    has_credits =
      map_get_any(credits, ["hasCredits", :hasCredits, "has_credits", :has_credits]) == true

    balance = map_get_any(credits, ["balance", :balance])

    cond do
      unlimited -> "unlimited"
      has_credits and is_number(balance) -> format_balance(balance)
      has_credits -> "available"
      true -> "none"
    end
  end

  defp format_balance(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_balance(value) when is_float(value), do: Float.to_string(value)
  defp format_balance(_), do: @em_dash

  defp relative_reset(diff_seconds) when diff_seconds <= 0, do: "reset ready"
  defp relative_reset(diff_seconds) when diff_seconds < 60, do: "in #{diff_seconds}s"

  defp relative_reset(diff_seconds) when diff_seconds < 3600 do
    "in #{div(diff_seconds, 60)}m"
  end

  defp relative_reset(diff_seconds) when diff_seconds < 86_400 do
    hours = div(diff_seconds, 3600)
    mins = div(rem(diff_seconds, 3600), 60)
    "in #{hours}h #{mins}m"
  end

  defp relative_reset(diff_seconds) do
    days = div(diff_seconds, 86_400)
    hours = div(rem(diff_seconds, 86_400), 3600)
    "in #{days}d #{hours}h"
  end

  defp do_flatten(map, now, prefix) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      key_string = to_string(k)
      path = prefix ++ [key_string]

      cond do
        is_nil(v) ->
          [{Enum.join(path, " / "), @em_dash}]

        is_map(v) ->
          case map_size(v) do
            0 -> [{Enum.join(path, " / "), "{}"}]
            _ -> do_flatten(v, now, path)
          end

        true ->
          [{Enum.join(path, " / "), format_value(key_string, v, now)}]
      end
    end)
  end

  defp humanize_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.downcase()
  end

  defp percent_key?(key), do: Regex.match?(~r/[Pp]ercent$/, key)

  defp minutes_key?(key) do
    Regex.match?(~r/(Mins|Minutes|_mins|_minutes)$/, key)
  end

  defp timestamp_key?(key) do
    Regex.match?(~r/(At|_at)$/, key)
  end

  # Returns the value for the first key that is actually present in `map`,
  # even if that value is `false` or `nil`. Use this when the caller needs to
  # distinguish "key missing" from "key present but explicitly nil/false" —
  # e.g. reading `has_credits: false` from a credits map.
  defp map_get_any(map, keys) when is_map(map) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp map_get_any(_, _), do: nil

  # Returns the first non-nil value for any of the given keys. Use this when
  # the caller wants a fall-through chain — e.g. `limitName || limitId` — and
  # treats an explicit nil the same as a missing key.
  defp first_non_nil(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp first_non_nil(_, _), do: nil
end
