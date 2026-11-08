# License

This IP core is dual-licensed.

SPDX-License-Identifier: `GPL-3.0-or-later OR LicenseRef-Commercial`

## GPL-3.0-or-later (open-source use)

Copyright (C) 2026 Ayoub Achour

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.

The full GPL-3.0 text is in [COPYING](COPYING). The canonical text is at <https://www.gnu.org/licenses/gpl-3.0.txt>.

**What this means in practice**: if you use this RTL in a project, the project itself (including any FPGA bitstream produced from it) must also be released under GPL-3.0-or-later. The GPL is "viral" — your downstream users must receive the same rights you received, including the right to the complete corresponding source.

If that is fine for your project, you are good to go. No fee, no email needed.

## Commercial license (closed-source / proprietary use)

If you want to use this core in a product whose source is not GPL — for example a closed-source self-encrypting drive, a storage appliance, an HSM, an enterprise NAS, an OPAL-class SSD controller, a closed-source full-disk-encryption layer for a custom OS, or any FPGA-based storage / DRM / KMS device — you need a commercial license.

The commercial license:

- removes the GPL viral requirement,
- grants you (and your company) the right to integrate the core into closed-source products,
- gives you a clear, written grant you can show to your customers and to a due-diligence auditor.

Commercial licenses are available on request: open a GitHub issue titled 'Commercial license request'. Do not post confidential details in the issue. Any commercial license is provided as is, without warranty, support or maintenance. This core is unverified (see README).

## Trademarks

"AES" is a public algorithm specified in NIST FIPS-197. "XTS" is the tweakable block-cipher mode standardised by IEEE Std 1619-2018. "XTS-AES" is the construction defined in that standard. No trademark claim is made on any of these names. You may state that this core is intended to implement XTS-AES-128 / IEEE 1619-2018; it has not been validated.

## Patents

To the best of the author's knowledge, AES, XTS, and the XTS-AES construction are not encumbered by patents in the United States or the European Union as of 2026. The author makes no warranty about patent freedom in other jurisdictions; if you ship hardware globally you are responsible for your own patent due diligence.
