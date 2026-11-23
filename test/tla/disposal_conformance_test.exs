defmodule Web.TLA.DisposalConformanceTest do
  # Compares the real `Web.using/2` with the specification
  # `tla/Disposal.tla`.
  #
  # The test makes random blocks of `using`, one in a different one. It runs
  # the real blocks, and it does the same steps on the specification. Then
  # it compares the resources that were released, and the error.
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Web

  alias Web.SuppressedError
  alias Web.Test.SpecModel
  alias Web.TestSupport.Disposable

  @depth 3

  # One block: its value, and the result of its disposal.
  defp block do
    tuple({member_of(["resource", "nil", "other"]), boolean()})
  end

  property "the blocks do each step as the specification permits" do
    check all(
            blocks <- list_of(block(), max_length: @depth),
            block_ok <- boolean(),
            max_runs: 300
          ) do
      model = run_model(blocks, block_ok)
      outcome = run_real(blocks, block_ok)

      released =
        for _level <- SpecModel.get(model, "released") do
          assert_received {:disposed, level, _symbol}
          level
        end

      refute_received {:disposed, _level, _symbol}

      assert released == SpecModel.get(model, "released")
      assert error(outcome) == SpecModel.get(model, "error")
      assert depth(outcome) == SpecModel.get(model, "depth")
      assert SpecModel.get(model, "phase") == "done"
    end
  end

  # ---------------------------------------------------------------------------
  # The specification
  # ---------------------------------------------------------------------------

  defp run_model(blocks, block_ok) do
    model =
      Enum.reduce_while(blocks, SpecModel.start("Disposal"), fn {kind, _ok}, model ->
        model = SpecModel.step!(model, "Declare", [kind])
        if kind == "other", do: {:halt, model}, else: {:cont, model}
      end)

    model =
      if SpecModel.get(model, "phase") == "enter" do
        SpecModel.step!(model, "EndBlock", [block_ok])
      else
        model
      end

    # The blocks end from the inner block to the outer block.
    blocks
    |> Enum.take(SpecModel.get(model, "level"))
    |> Enum.reverse()
    |> Enum.reduce(model, fn {_kind, ok}, model -> SpecModel.step!(model, "Release", [ok]) end)
    |> SpecModel.step!("Finish")
  end

  # ---------------------------------------------------------------------------
  # The real blocks
  # ---------------------------------------------------------------------------

  defp run_real(blocks, block_ok) do
    {:ok, nest(blocks, 1, block_ok)}
  rescue
    exception -> {:error, exception}
  end

  defp nest([], _level, true), do: :block
  defp nest([], _level, false), do: raise("block")

  defp nest([{kind, ok} | rest], level, block_ok) do
    using value(kind, level, ok) do
      nest(rest, level + 1, block_ok)
    end
  end

  defp value("resource", level, true), do: Disposable.new(level, :ok)
  defp value("resource", level, false), do: Disposable.new(level, :raise)
  defp value("nil", _level, _ok), do: nil
  defp value("other", level, _ok), do: {:not_disposable, level}

  defp error({:ok, :block}), do: "none"
  defp error({:error, %Web.TypeError{}}), do: "type"
  defp error({:error, %RuntimeError{message: "block"}}), do: "block"
  defp error({:error, %RuntimeError{message: "the disposal of" <> _}}), do: "disposal"
  defp error({:error, %SuppressedError{}}), do: "suppressed"

  # The number of SuppressedError in the error.
  defp depth({:error, %SuppressedError{suppressed: suppressed}}) do
    1 + depth({:error, suppressed})
  end

  defp depth(_outcome), do: 0
end
