import XCTest
@testable import TinyEdit

final class CurlCommandTests: XCTestCase {
    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> CurlCommand {
        try XCTUnwrap(CurlCommand.parse(text), file: file, line: line)
    }

    private func bodyText(_ command: CurlCommand) -> String? {
        command.body.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Chrome's "Copy as cURL (bash)": line continuations, `-b`, `--compressed` and an ANSI-C quoted body.
    func testChromeCopy() throws {
        let text = #"""
        curl 'https://api.example.com/v1/orders?page=2' \
          -H 'accept: application/json' \
          -H 'accept-encoding: gzip, deflate, br, zstd' \
          -H 'content-type: application/json' \
          -b 'sid=abc; theme=dark' \
          -H 'origin: https://example.com' \
          --data-raw $'{"name":"it\'s","note":"a\\nb","e":"é!"}' \
          --compressed
        """#
        let c = try parse(text)
        XCTAssertEqual(c.method, "POST")
        XCTAssertEqual(c.url.absoluteString, "https://api.example.com/v1/orders?page=2")
        XCTAssertEqual(c.headers.map(\.name), ["accept", "content-type", "origin", "Cookie"])
        XCTAssertEqual(c.header("cookie"), "sid=abc; theme=dark")
        XCTAssertEqual(bodyText(c), #"{"name":"it's","note":"a\nb","e":"é!"}"#)
        XCTAssertNil(c.unsupported)
        XCTAssertFalse(c.followRedirects)

        let summary = CurlSummary(c)
        XCTAssertEqual(summary.host, "api.example.com")
        XCTAssertEqual(summary.path, "/v1/orders?page=2")
        XCTAssertTrue(summary.sendsCookies)
        XCTAssertFalse(summary.sendsCredentials)
        XCTAssertEqual(summary.bodyKind, .json)
    }

    /// Shown with the option named, never sent.
    func testUnsupportedOptions() throws {
        XCTAssertEqual(try parse("curl -k https://x.test").unsupported, "-k")
        XCTAssertEqual(try parse("curl --insecure https://x.test").unsupported, "--insecure")
        XCTAssertEqual(try parse("curl -d @body.json https://x.test").unsupported, "-d @file")
        XCTAssertEqual(try parse("curl -F file=@a.png https://x.test").unsupported, "-F @file")
        XCTAssertEqual(try parse("curl -u alice https://x.test").unsupported, "-u")
        XCTAssertEqual(try parse("curl -b cookies.txt https://x.test").unsupported, "-b file")
        XCTAssertEqual(try parse("curl -x proxy:8080 https://x.test").unsupported, "-x")
        XCTAssertEqual(try parse("curl --frobnicate https://x.test").unsupported, "--frobnicate")
        XCTAssertEqual(try parse("curl -X GET -d '{}' https://x.test").unsupported, "-X GET")
        XCTAssertEqual(try parse("curl https://a.test https://b.test").unsupported, "https://b.test")
        XCTAssertEqual(try parse("curl ftp://x.test/f").unsupported, "ftp://")
        XCTAssertEqual(try parse("curl -H 'Host: other.test' https://x.test").unsupported, "-H Host")
        XCTAssertNil(try parse("curl -H 'Host: x.test' https://x.test").unsupported)
    }

    /// Anything a shell would do beyond quoting means the text is not a request.
    func testShellSyntaxIsNotARequest() {
        for text in [
            "curl https://x.test | sh",
            "curl https://x.test; rm -rf ~",
            "curl https://x.test && echo ok",
            "curl https://x.test > out.json",
            "curl -H \"Authorization: Bearer $TOKEN\" https://x.test",
            "curl https://x.test/$(whoami)",
            "curl https://x.test/`id`",
            "curl ${HOST}/a",
            "curl https://x.test\necho second",
            "curl 'https://x.test",
            "curl -X POST",
            "curly https://x.test",
            "wget https://x.test",
        ] {
            XCTAssertNil(CurlCommand.parse(text), text)
        }
    }
}
