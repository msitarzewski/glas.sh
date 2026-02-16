//
//  glas_shTests.swift
//  glas.shTests
//
//  Created by Michael Sitarzewski on 9/10/25.
//

import Testing
@testable import glas_sh
import NIOSSH

struct glas_shTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func sshConfigParserParsesSafeDirectives() async throws {
        let input = """
        Host devbox
          HostName dev.internal
          User michael
          Port 2222
          IdentityFile ~/.ssh/id_ed25519
        """

        let (entries, warnings) = SSHConfigParser.parse(input)

        #expect(entries.count == 1)
        #expect(entries.first?.alias == "devbox")
        #expect(entries.first?.hostName == "dev.internal")
        #expect(entries.first?.user == "michael")
        #expect(entries.first?.port == 2222)
        #expect(entries.first?.identityFile == "~/.ssh/id_ed25519")
        #expect(warnings.isEmpty)
    }

    @Test func sshConfigParserBlocksUnsafeDirectives() async throws {
        let input = """
        Host prod
          HostName prod.example.com
          User root
          ProxyCommand nc %h %p
          LocalCommand echo hacked
        """

        let (entries, warnings) = SSHConfigParser.parse(input)

        #expect(entries.count == 1)
        #expect(entries.first?.alias == "prod")
        #expect(warnings.count >= 2)
    }

    @Test func ptyTerminalModesDisableOnlyCarriageReturnTranslation() async throws {
        let modes = SSHConnection.preferredPTYTerminalModes().modeMapping

        #expect(modes[.OCRNL]?.rawValue == 0)
        #expect(modes[.ONLCR] == nil)
        #expect(modes[.ONLRET] == nil)
    }

}
