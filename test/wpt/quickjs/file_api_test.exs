defmodule Web.WPT.QuickJS.FileAPITest do
  # Runs the files of web-platform-tests for the File API and the `FormData`
  # of the XMLHttpRequest Standard: `Blob`, `File`, and `FormData`, with no
  # change, in QuickJS against the library. See `Web.Test.QuickJS.Bridge`, and
  # `Web.Test.QuickJS.WPT` for the lists of expected results.
  use ExUnit.Case, async: true

  # A file of WPT can have thousands of tests, and WPT gives some files a
  # long time limit (`META: timeout=long`).
  @moduletag timeout: 300_000

  alias Web.Test.QuickJS.WPT

  @files [
    "FileAPI/blob/Blob-array-buffer.any.js",
    "FileAPI/blob/Blob-bytes.any.js",
    "FileAPI/blob/Blob-constructor-detached-buffer.any.js",
    "FileAPI/blob/Blob-constructor-endings.any.js",
    "FileAPI/blob/Blob-constructor.any.js",
    "FileAPI/blob/Blob-newobject.any.js",
    "FileAPI/blob/Blob-slice-overflow.any.js",
    "FileAPI/blob/Blob-slice.any.js",
    "FileAPI/blob/Blob-stream.any.js",
    "FileAPI/blob/Blob-text.any.js",
    "FileAPI/blob/Blob-textStream.any.js",
    "FileAPI/file/File-constructor-endings.any.js",
    "FileAPI/file/File-constructor.any.js",
    "FileAPI/file/send-file-formdata-controls.any.js",
    "FileAPI/file/send-file-formdata-punctuation.any.js",
    "FileAPI/file/send-file-formdata-utf-8.any.js",
    "FileAPI/file/send-file-formdata.any.js",
    "FileAPI/fileReader.any.js",
    "FileAPI/reading-data-section/Determining-Encoding.any.js",
    "FileAPI/reading-data-section/FileReader-event-handler-attributes.any.js",
    "FileAPI/reading-data-section/FileReader-multiple-reads.any.js",
    "FileAPI/reading-data-section/filereader_abort.any.js",
    "FileAPI/reading-data-section/filereader_error.any.js",
    "FileAPI/reading-data-section/filereader_events.any.js",
    "FileAPI/reading-data-section/filereader_readAsArrayBuffer.any.js",
    "FileAPI/reading-data-section/filereader_readAsBinaryString.any.js",
    "FileAPI/reading-data-section/filereader_readAsDataURL.any.js",
    "FileAPI/reading-data-section/filereader_readAsText.any.js",
    "FileAPI/reading-data-section/filereader_readAsText_blob_type_charset.any.js",
    "FileAPI/reading-data-section/filereader_readystate.any.js",
    "FileAPI/reading-data-section/filereader_result.any.js",
    "FileAPI/unicode.any.js",
    "FileAPI/url/url-format.any.js",
    "FileAPI/url/url-with-fetch.any.js",
    "FileAPI/url/url-with-xhr.any.js",
    "xhr/formdata/append.any.js",
    "xhr/formdata/constructor.any.js",
    "xhr/formdata/delete.any.js",
    "xhr/formdata/foreach.any.js",
    "xhr/formdata/get.any.js",
    "xhr/formdata/has.any.js",
    "xhr/formdata/iteration.any.js",
    "xhr/formdata/set-blob.any.js",
    "xhr/formdata/set.any.js"
  ]

  for path <- @files do
    test path do
      WPT.check!(unquote(path))
    end
  end
end
