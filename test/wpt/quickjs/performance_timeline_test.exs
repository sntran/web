defmodule Web.WPT.QuickJS.PerformanceTimelineTest do
  # Runs the files of web-platform-tests for the Performance Timeline and
  # User Timing Standards: `performance`, its marks and measures,
  # `PerformanceObserver`, and `PerformanceObserverEntryList`, with no
  # change, in QuickJS against the library. See `Web.Test.QuickJS.Bridge`,
  # and `Web.Test.QuickJS.WPT` for the lists of expected results.
  #
  # The executors of a run act for one global object, as the code of one
  # page: see `page_timeline/1` in the bridge.
  #
  # Not in the list: the files for a window or a worker only, the tentative
  # tests, and `idlharness.any.js`.
  use ExUnit.Case, async: true

  # A file of WPT can have thousands of tests, and WPT gives some files a
  # long time limit (`META: timeout=long`). The library writes a warning
  # for an entry type that it does not support, and an error for a callback
  # that throws: the log shows only for a test that fails.
  @moduletag timeout: 300_000
  @moduletag :capture_log

  alias Web.Test.QuickJS.WPT

  @files [
    "performance-timeline/buffered-flag-after-timeout.any.js",
    "performance-timeline/buffered-flag-observer.any.js",
    "performance-timeline/case-sensitivity.any.js",
    "performance-timeline/droppedentriescount.any.js",
    "performance-timeline/multiple-buffered-flag-observers.any.js",
    "performance-timeline/observer-buffered-false.any.js",
    "performance-timeline/performanceentry-tojson.any.js",
    "performance-timeline/po-callback-mutate.any.js",
    "performance-timeline/po-disconnect-removes-observed-types.any.js",
    "performance-timeline/po-disconnect.any.js",
    "performance-timeline/po-entries-sort.any.js",
    "performance-timeline/po-getentries.any.js",
    "performance-timeline/po-mark-measure.any.js",
    "performance-timeline/po-observe-repeated-type.any.js",
    "performance-timeline/po-observe-type.any.js",
    "performance-timeline/po-observe.any.js",
    "performance-timeline/po-takeRecords.any.js",
    "performance-timeline/supportedEntryTypes.any.js",
    "performance-timeline/webtiming-resolution.any.js",
    "user-timing/buffered-flag.any.js",
    "user-timing/case-sensitivity.any.js",
    "user-timing/clear_all_marks.any.js",
    "user-timing/clear_all_measures.any.js",
    "user-timing/clear_non_existent_mark.any.js",
    "user-timing/clear_non_existent_measure.any.js",
    "user-timing/clear_one_mark.any.js",
    "user-timing/clear_one_measure.any.js",
    "user-timing/entry_type.any.js",
    "user-timing/mark-entry-constructor.any.js",
    "user-timing/mark-errors.any.js",
    "user-timing/mark-l3.any.js",
    "user-timing/mark-measure-return-objects.any.js",
    "user-timing/mark.any.js",
    "user-timing/measure-l3.any.js",
    "user-timing/measure-with-dict.any.js",
    "user-timing/measure_syntax_err.any.js",
    "user-timing/structured-serialize-detail.any.js",
    "user-timing/supported-usertiming-types.any.js",
    "user-timing/user_timing_exists.any.js"
  ]

  for path <- @files do
    test path do
      WPT.check!(unquote(path))
    end
  end
end
