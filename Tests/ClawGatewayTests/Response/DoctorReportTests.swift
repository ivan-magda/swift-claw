import Testing

@testable import ClawGateway

@Suite struct DoctorReportTests {
  @Test func okWhenAllChecksPass() {
    // given
    var report = DoctorReport()

    // when
    report.add(key: "config", value: "OK")
    report.add(key: "allowlist.owners", value: "1", ok: true)

    // then
    #expect(report.ok)
  }

  @Test func failsIfAnyCheckFails() {
    // given
    var report = DoctorReport()

    // when
    report.add(key: "config", value: "OK")
    report.add(key: "allowlist.owners", value: "0", ok: false)

    // then
    #expect(report.ok == false)
  }

  @Test func textRenderShowsKeysAndMarkers() {
    // given
    var report = DoctorReport()
    report.add(key: "config", value: "OK")
    report.add(key: "allowlist.owners", value: "0", ok: false)

    // when
    let text = report.renderText()

    // then
    #expect(text.contains("config"))
    #expect(text.contains("FAIL"))
  }

  @Test func mixedReportRendersOkAndFailMarkers() {
    // given
    var report = DoctorReport()
    report.add(key: "db.writable", value: "true")
    report.add(key: "allowlist.owners", value: "0", ok: false)

    // when
    let text = report.renderText()

    // then
    #expect(text.contains("[ok]"))
    #expect(text.contains("[FAIL]"))
  }

  @Test func jsonRenderIsParseable() {
    // given
    var report = DoctorReport()
    report.add(key: "config", value: "OK")

    // when
    let json = report.renderJSON()

    // then
    #expect(json.contains("\"config\""))
    #expect(json.contains("\"ok\""))
  }
}
