# M0 - MLS feasibility spike: zaznam vysledku

Datum: 2026-09-17. Autor: Claude (Fable 5.1), na pokyn Martina Zahalky. Stroj: Windows 11 Pro 10.0.26200, solo-founder notebook (zadny CI runner).

Otazka: Zvladne Jay (Flutter 3.41.2, cile web/Android/iOS/Windows/macOS, dnes ciste Dart krypto) provozovat MLS (RFC 9420) pres OpenMLS (Rust) na klientovi, vcetne webu (WASM), aby v kroku 2 business skupiny nahradily dnesni per-recipient fan-out a auditni clen videl stejny ciphertext jako ostatni (uzavreni meze KB2)?

Doporuceni: GO s vyjimkami. Rust jadro nad openmls funguje a proslo scenarem z planu. Nativni klienti (Windows, pravdepodobne macOS/Linux) a Android jsou bez vyhrad. Web funguje, ale jen pres threaded WASM, coz vyzaduje cross-origin izolaci (COOP/COEP) - novy provozni pozadavek, ktery dnesni staticwebapp.config.json nema a ktery muze kolidovat s existujicim drift/sqlite3 WASM workerem. iOS/macOS nebylo mozne na tomto stroji sestavit (NOT_RUN), posouzeno jen z dokumentace. Podrobnosti a presny dopad na Azure Static Web Apps v sekci 3.4.

---

## 1. Prostredi a nastroje (presne verze)

| Nastroj | Verze | Zdroj |
|---|---|---|
| Rust (rustc/cargo) | 1.98.1 / 1.98.1 | rustc --version; byl jiz nainstalovan na stroji pred spikem (rustup 1.29.1 pritomen), instalace pres winget install --id Rustlang.Rustup probehla jako no-op ("unchanged"), rustup default stable proveden |
| Cile Rustu pridane | wasm32-unknown-unknown (stable i nightly), aarch64-linux-android, armv7-linux-androideabi, x86_64-linux-android, i686-linux-android | rustup target add |
| MSVC linker | Visual Studio Community 2026 (18.10.0), VC Tools 14.51.36231 | vswhere.exe, cl.exe nalezen v VC/Tools/MSVC/14.51.36231/bin/Hostx64/x64 - jiz nainstalovano na stroji, nebylo soucasti tohoto spiku |
| Android NDK | 27.1.12297006 a 28.2.13676358 | %LOCALAPPDATA%/Android/Sdk/ndk - jiz pritomno |
| Flutter / Dart | 3.41.2 (stable) / 3.11.0 | flutter --version |
| openmls | 0.9.0 | crates.io, resolved 2026-09-17 |
| openmls_rust_crypto | 0.6.0 | crates.io |
| openmls_basic_credential | 0.6.0 | crates.io |
| openmls_traits | 0.6.0 | crates.io |
| flutter_rust_bridge (Dart) | 2.13.0 | flutter pub add |
| flutter_rust_bridge_codegen (CLI) | 2.13.0 | cargo install flutter_rust_bridge_codegen --locked |
| wasm-pack | 0.15.0 | cargo install wasm-pack --locked |
| wasm-bindgen, wasm-opt | auto-instalovano wasm-pack pri prvnim behu | - |
| cargo-expand | auto-instalovano flutter_rust_bridge_codegen pri prvnim behu | - |

Instalacni pravidlo ze zadani (Rust jen pres winget Rustlang.Rustup) bylo dodrzeno formalne, i kdyz Rust byl na stroji uz pritomny. Vsechny ostatni nastroje (flutter_rust_bridge_codegen, wasm-pack, cargo-expand) byly instalovany vyhradne pres cargo install / automatickym auto-installerem tehoz - v souladu s pravidlem "jen spravci balicku, zadne cizi instalery".

Nainstalovano navic oproti zadani a nutne pro build-web: nightly Rust toolchain + rust-src komponenta (rustup toolchain install nightly probehlo automaticky pres wasm-pack/RUSTUP_TOOLCHAIN=nightly; rustup component add rust-src --toolchain nightly spusteno rucne, jinak build-web padal na chybejicim Cargo.lock standardni knihovny). Duvod viz 3.3.

---

## 2. Rust jadro - spikes/mls/mls_core

Minimalni API nad openmls v src/lib.rs: MlsClient::new_identity, create_key_package_bytes, create_group, add_member_from_bytes (validuje KeyPackage pred pridanim), join_from_welcome, encrypt, process_incoming (rozlisi application message vs. Commit a rovnou ho mergne), remove_member, group_id/reload_group_from_storage (export/import). Rozhrani je zamerne bytes-in/bytes-out (zadny openmls typ neprekracuje hranici) - to je zaroven presne to, co potrebuje FFI hranice na klienta (sekce 3).

### K06 - PASS: cargo test --release (tests/scenario.rs)

Scenar ze zadani: Alice zalozi skupinu, prida Boba a Auditora (tretiho radoveho clena), Alice posle zpravu -> Bob i Auditor desifruji stejny ciphertext na stejny plaintext (assert_eq!(bob_plaintext, auditor_plaintext)) - to je presne uzavreni meze KB2 z planu. Bob odpovi, Alice odebere Boba, Bob uz nedokaze desifrovat novou zpravu (bob_result.is_err() overeno), stav Auditora prezije export/import (reload_group_from_storage po group_id() - simulace restartu procesu, overeno desifrovanim nove zpravy po reloadu).

```
$ cargo test --release
running 1 test
test business_group_scenario ... ok
```

Poznamka k "exportu/importu": openmls StorageProvider (zde OpenMlsRustCrypto / in-memory MemoryStorage) persistuje inkrementalne po kazde operaci; MlsGroup::load(storage, &group_id) je stejna cesta, kterou by pouzil i diskovy storage provider po restartu procesu. Skutecne perzistentni uloziste (SQLCipher/Drift na klientovi) nebylo v rozsahu spiku - jen overeno, ze API pro to existuje a funguje.

### K06 - PASS: cargo build --target wasm32-unknown-unknown --release

Holy mls_core (bez wasm-bindgen/FRB obalu) se ciste prelozi pro wasm32-unknown-unknown stable Rustem, ale jen po pridani openmls "js" feature (jinak compile_error! - OpenMLS bez ni na wasm nejde zkompilovat vubec, potrebuje JS API pro cas a nahodna cisla) a po vynuceni getrandom 0.2/0.4 na feature js/wasm_js (tranzitivni zavislosti to samy nenastavi). Viz Cargo.toml, sekce [target.wasm32-unknown-unknown.dependencies].

- Velikost .wasm (release, bez wasm-bindgen glue, ciste cdylib s crypto): 476 079 B raw / 100 527 B gzip. Tohle cislo dokazuje jen prelozitelnost jadra, neni to nasaditelny artefakt (chybi JS binding).

### K06 - PASS: cargo run --release --example timing (nativni, viz sekce 4)

---

## 3. Flutter binding - spikes/mls/mls_flutter

### 3.1 Volba nastroje

flutter_rust_bridge v2.13.0 (aktualni stable k 2026-09-17, zjisteno pres flutter pub add a flutter_rust_bridge_codegen --version, shoduje se). Integrace pres flutter_rust_bridge_codegen create - vygenerovala rust_builder/cargokit (CargoKit, oficialni FRB build backend pro Android/iOS/macOS/Windows/Linux - kompiluje Rust per-target Gradle/Xcode/CMake tasky) a rust/ crate. Do rust/Cargo.toml pridan mls_core jako path-dependency; tenky obal rust/src/api/mls.rs (MlsClientHandle) drzi mls_core::MlsClient a exponuje stejne bytes-in/bytes-out metody - flutter_rust_bridge_codegen generate z nej automaticky odvodil Dart tridu s Future<...> metodami (FRB v2 vola Rust asynchronne z izolatu/workeru, ne blokujicim volanim na UI threadu).

Alternativa wasm-bindgen + dart:js_interop naprimo (bez FRB) nebyla zkousena end-to-end - u FRB fungovalo vse z prvni rozumne konfigurace, extra vrstva vlastniho JS interop by pro tento rozsah API (7 metod, bytes-in/bytes-out) neprinesla nic navic a jen znovu naimplementovala to, co FRB dela automaticky (marshalling, chybove stavy, async wrapping). Pokud by se v kroku 2 ukazalo, ze threaded-WASM pozadavek FRB (3.3) je neunosny, wasm-bindgen naprimo je realny fallback - protoze 3.2 dokazuje, ze holе jadro jde prelozit i bez threads; s wasm-bindgen by slo udelat nethreadovany build stejne jako u sqlite3 WASM workeru, ktery Jay uz ma. Doporuceni: pokud krok 2 nastane, overit nejdrive nethreading pres wasm-bindgen naprimo, nez threaded FRB cestu do produkce.

### 3.2 Windows desktop - PASS

```
$ flutter build windows
Building Windows application...
Built build\windows\x64\runner\Release\mls_flutter.exe
```

rust_lib_mls_flutter.dll (staticky linkuje mls_core + openmls): 3 483 648 B (3.48 MB), zabalena do Release buildu. CargoKit zavolal cargo build --release pro x86_64-pc-windows-msvc transparentne z Flutter build procesu - zadna rucni vcvarsall gymnastika nebyla na strane Fluttera potreba (CargoKit si MSVC najde sam), tu jsem potreboval jen pro primo cargo build/cargo test volani mimo Flutter.

### 3.3 Web (WASM) - PASS, s podminkou (threaded WASM => COOP/COEP)

flutter_rust_bridge_codegen build-web --release interne vola:
```
wasm-pack build -t no-modules -d .../web/pkg --no-typescript --out-name rust_lib_mls_flutter rust -- -Z build-std=std,panic_abort
```
s RUSTFLAGS = -C target-feature=+atomics,+bulk-memory,+mutable-globals -C link-args=--shared-memory ... a RUSTUP_TOOLCHAIN=nightly.

Zjisteni: FRB v2.13.0 defaultne stavi threaded WASM (+atomics, --shared-memory) - ne obycejny wasm32-unknown-unknown. Duvod: FRB potrebuje z JS zavolat do Rustu synchronne (viz CHANGELOG 2.13.0-beta.6: "Fail fast for locked Rust opaque sync calls on web"), a prohlizec nema nativni blokujici volani - FRB to resi Web Workerem + Atomics.wait, coz vyzaduje SharedArrayBuffer, coz vyzaduje cross-origin izolaci (Cross-Origin-Opener-Policy: same-origin + Cross-Origin-Embedder-Policy: require-corp nebo credentialless).

Postup a co bylo potreba navic oproti zadani (zaznamenano, ne v rozporu s pravidly - slo o rustup/cargo, ne cizi instalery):
1. cargo install wasm-pack --locked (0.15.0) - FRB build-web ho vyzaduje a sam ho nenainstaluje.
2. rustup toolchain install nightly - probehlo automaticky (wasm-pack/FRB si nightly vyzadaly pres RUSTUP_TOOLCHAIN), ale bez rust-src komponenty selhalo na chybe "...Cargo.lock does not exist, unable to build with the standard library" - protoze -Z build-std (nutne pro threaded WASM, std knihovna musi byt prelozena s +atomics) potrebuje zdrojaky std. Oprava: rustup component add rust-src --toolchain nightly.
3. Po tomto wasm-pack build probehl (1m34s kompilace + 2m instalace wasm-bindgen/wasm-opt), build PASS.

```
[INFO]: Your wasm pkg is ready to publish at .../mls_flutter/web/pkg.
```

Velikost vystupu (web/pkg/rust_lib_mls_flutter_bg.wasm, threaded, s wasm-bindgen glue a debug symboly z openmls+mls_core): 1 974 504 B raw (1.97 MB) / 713 573 B gzip. Nasobne vic nez hole jadro z 2. (476 KB), protoze je tu navic wasm-bindgen glue, TLS/threading runtime a openmls "js" feature cesta (o neco jina nez wasm32-unknown-unknown plain build).

flutter build web --release pak korektne zabalil web/pkg/rust_lib_mls_flutter_bg.wasm (1.97 MB) do build/web/pkg/ vedle zbytku Flutter web outputu (canvaskit atd.) - PASS, zadna rucni uprava index.html nebyla potreba (sablona FRB create uz ho zapojila).

Netestovano v tomto spiku: samotne spusteni v prohlizeci (flutter run -d chrome) - Chrome/Edge s cross-origin izolaci potrebuje realny HTTP server s COOP/COEP hlavickami, ne file://; preview_start v tomto prostredi neumi libovolne nastavit response headers dev serveru. Toto je jedina mezera K06: build je PASS, runtime-v-prohlizeci je NOT_RUN (chybi overeni, ne indikace problemu - nastaveni hlavicek je bezny a zdokumentovany FRB/Flutter web postup, jen jsem ho v tomto stroji nerozjel end-to-end).

#### 3.4 Dopad na Azure Static Web Apps a existujici sqlite3/drift worker

src/client/calltype/web/staticwebapp.config.json dnes nenastavuje zadne COOP/COEP hlavicky (jen navigationFallback a MIME typ pro .wasm). Drift/sqlite3 WASM worker (sqlite3.wasm + drift_worker.js, viz lib/core/storage/database.dart) dnes funguje bez cross-origin izolace - drift/sqlite3.wasm v teto konfiguraci nepouziva SharedArrayBuffer (single-threaded WASM), takze dnesni produkcni web nepotrebuje COOP/COEP vubec.

Kdyby krok 2 nasadil threaded MLS WASM (3.3), bylo by nutne pridat do staticwebapp.config.json (Azure SWA to podporuje pres globalHeaders):
```json
"globalHeaders": {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp"
}
```
Riziko: require-corp vynucuje, ze kazdy cross-origin subresource (fonty z Google Fonts, pripadny CDN, Firebase SDK skripty, WebRTC/TURN signalizace pres jiny origin) musi nest Cross-Origin-Resource-Policy nebo byt servirovan s CORS - jinak prohlizec subresource zablokuje. To je realne riziko regrese pro cokoliv, co Jay web dnes nacita cross-origin (nebylo v tomto spiku auditovano, mimo rozsah). Mirnejsi varianta credentialless existuje (COEP: credentialless), ale je podporovana jen v novejsich Chromiu/Firefoxu - kompatibilitu se zbytkem podporovanych prohlizecu Jay by bylo nutne overit zvlast.

Odpoved na otazku ze zadani: ano, staticwebapp.config.json COOP/COEP nastavit umi (globalHeaders), ale nasazeni by mohlo rozbit cokoliv dalsiho na strance nactene cross-origin bez CORP hlavicky - nutna samostatna revize pred krokem 2, ne automaticky GO. Existujici drift/sqlite3 worker samotny by thready/COOP/COEP nerozbily (je dnes single-threaded), ale sdilet stranku s threaded MLS WASM by ho vystavilo stejne cross-origin izolaci jako celou stranku - bez zjisteneho konfliktu, ale netestovano pohromade.

Fallback, pokud se toto ukaze neunosne: wasm-bindgen naprimo bez FRB, nethreadovany build (jako mls_core wasm32 build v 2.) + rucni dart:js_interop volani - zadna potreba COOP/COEP, protoze bez Atomics.wait FRB nemusi blokovat hlavni vlakno (ale volani do Rustu z Dartu by pak muselo byt asynchronni/message-passing na urovni aplikace, ne skryte za Future jako u FRB - vic rucni prace, zadna nova infrastrukturni zavislost).

### 3.5 Android - PASS (debug)

```
$ flutter build apk --debug
INFO: Building rust_lib_mls_flutter for armv7-linux-androideabi
INFO: Building rust_lib_mls_flutter for aarch64-linux-android
INFO: Building rust_lib_mls_flutter for x86_64-linux-android
INFO: Building rust_lib_mls_flutter for i686-linux-android
Built build\app\outputs\flutter-apk\app-debug.apk
```
CargoKit sestavil mls_core+openmls pro vsechny 4 ABI pres existujici Android NDK (27.1.12297006) bez dalsiho zasahu. Release build (flutter build apk --release, R8/ProGuard) nebyl v tomto spiku zkousen - casovy box; neni duvod ocekavat problem (CargoKit generuje ciste .so per-ABI, ktere R8 nijak neanalyzuje), ale K06 status pro release konkretne je NOT_RUN, ne PASS.

### 3.6 iOS / macOS - NOT_RUN (jen z dokumentace)

Nelze sestavit na Windows 11 (chybi Xcode/toolchain). Z dokumentace FRB + CargoKit: CargoKit ma oficialni podporu pro iOS (.xcframework) a macOS (CocoaPods/SPM), stejny build-backend jako Windows/Android vyse - ocekavany rozdil je jen v tom, ze cargo build ciluje aarch64-apple-ios/x86_64-apple-darwin/aarch64-apple-darwin misto MSVC/Android NDK. Riziko specificke pro CallType: spec 8.1 uz identifikuje mobil (obzvlaste iOS push/notification service extension) jako nejvetsi riziko projektu nezavisle na MLS - pridani Rust static lib do iOS extension procesu (pametovy limit ~24MB, cas ~30s) by potrebovalo overit, ze openmls pametova stopa se do techto limitu vejde; to je nova otazka, kterou tento spike neumi zodpovedet bez skutecneho macOS stroje. Status: NOT_RUN, ne UNSUPPORTED - nic v dokumentaci nenaznacuje principialni nemoznost.

---

## 4. Mereni (nativni, release build, jednorazove - bez warmupu/statistiky)

cargo run --release --example timing (Windows, x86_64-pc-windows-msvc, RustCrypto backend - ne libcrux):

```
n=   3  create=    1.04ms  add_avg=    1.27ms (add_total=    2.54ms)  encrypt=   46.40us  decrypt=   76.00us
n=  50  create=  187.10us  add_avg=    1.33ms (add_total=   65.08ms)  encrypt=   65.90us  decrypt=   72.50us
n= 250  create=  154.20us  add_avg=    4.27ms (add_total=    1.06s)  encrypt=   77.10us  decrypt=   73.30us
```

Interpretace:
- create/encrypt/decrypt jsou prakticky konstantni vuci velikosti skupiny (radove desitky az stovky mikrosekund) - MLS tree encryption drzi slibovanou O(log n) charakteristiku pro aplikacni zpravy.
- add member roste s velikosti skupiny (1.27 ms pri n=3 az 4.27 ms pri n=249 clenech), protoze kazdy add_members prepocitava a znovu-sifruje cast stromu (path secrets) - u 250clenske skupiny sestavene "po jednom" to da ~1.06 s celkem, coz je jednorazovy naklad pri zakladani velke business skupiny, ne per-message naklad. Realny add_members volany pro vic key packages najednou (batch add) by mel tento naklad rozpocitat efektivneji, nez pridavat 249x po jednom (netestovano - mimo rozsah spiku).
- WASM (threaded, prohlizec): netestovano - vyzadovalo by JS harness (Node/Chrome headless), ktery se do casoveho boxu spiku nevesel; nativni cisla vyse ukazuji dolni mez, WASM bude pomalejsi (typicky 1.5-3x u crypto-heavy kodu, ale bez mereni na tomto stroji jde jen o obecny odhad, ne tvrzeni).
- Pamet: nemereno explicitne (zadny profiler v rozsahu); .wasm binarka (2.) a nativni .dll (3.48 MB, 3.2) davaji orientacni odhad staticke velikosti kodu, ne runtime heap.

---

## 5. Persistence stavu skupiny

openmls StorageProvider trait (implementovany OpenMlsRustCrypto/MemoryStorage v tomto spiku) persistuje inkrementalne po kazde group operaci (add/remove/commit/message). Scenar v tests/scenario.rs overuje round-trip: group_id() -> reload_group_from_storage() reprodukuje clenstvi i schopnost desifrovat novou zpravu. Pro produkci by "storage" musel byt disk-backed (na klientovi: SQLCipher/Drift, stejne jako dnesni zbytek Jay stavu) - openmls_traits::StorageProvider je implementovatelne rozhrani presne pro tento ucel (existuje i oficialni openmls_sqlite_storage crate v ekosystemu, nebyl v tomto spiku zkousen, ale je primo relevantni volba pro krok 2 na klientovi).

---

## 6. Soubezne commit zpravy

Nebylo v tomto spiku prakticky testovano (zadny multi-writer scenar v scenario.rs). Z designu MLS/RFC 9420: kazda epocha skupiny ma prave jeden platny Commit; druhy Commit proti stejne epose je odmitnut (process_message vrati chybu, ne pad). To je presne nova trida konfliktu, kterou dnesni per-recipient fan-out nema - viz sekce 7.

---

## 7. Server implications (design only)

Co by Delivery Service potreboval navic oproti dnesku pro MLS (krok 2), strucne:

- KeyPackage store/consumption. Analogie k dnesnimu OneTimePreKey, ale s vlastni expiraci (Lifetime v KeyPackage) a nutnosti atomicky vydat-a-spotrebovat (aby dva soubezni add_members nepouzili stejny KeyPackage) - dnesni OneTimePreKey resi totez, princip SELECT ... FOR UPDATE SKIP LOCKED z planu 6.2.4 se da znovu pouzit beze zmeny.
- Poradi handshake (Commit) zprav. Nove oproti dnesku: server musi serializovat Commity per-skupina a odmitnout Commit, ktery neodpovida aktualni epose skupiny (podobne jako dnesni MessageId/ACK disciplina, ale navic s epoch-cislem jako monotonni sekvenci). Bez toho muze vzniknout fork stromu (dva klienti si mysli, ze jsou v ruznych "verzich" skupiny).
- Doruceni Welcome. Welcome se doruje jen novemu clenovi, ne broadcastem jako Commit - novy, dosud neexistujici dorucovaci kanal (prijemce jeste neni clen skupiny, takze nejde pouzit stavajici group-fanout cestu).
- Soubezne commity. Server musi zvolit viteze (first-committer-wins) a druheho klienta informovat, ze jeho Commit byl odmitnut - klient pak musi commit zopakovat proti nove epose. To je nova trida retry logiky na klientovi, kterou dnesni navrh nema (dnesni fan-out nema pojem "epocha").
- Co potrebuje auditor (spec 5.3, KB3). MLS forward secrecy zahazuje stare epoch klice - to nemeni dnesni vzor "auditor je radny clen, desifruje v realnem case a hash/re-encrypt hned" (E03/E03b v planu): auditor musi zpracovat aplikacni zpravu v okamziku doruceni (stejne jako dnes), ne zpetne. MLS pouze meni jak se auditor dostane do skupiny (Add proposal/Commit misto pridani do mapy encryptedPayloads) a garantuje, ze vidi identicky ciphertext/plaintext jako ostatni clenove - to je presne uzavreni meze KB2, overene scenarem v sekci 2.

---

## 8. Rizika

| Riziko | Zavaznost | Poznamka / zdroj |
|---|---|---|
| OpenMLS audit | Stredni - zmirneno | Nezavisly bezpecnostni audit SRLabs, sponzorovano Sovereign Tech Agency, publikovano 2026-05-27: 8 nalezu, 1 High severity, 7 opraveno (v openmls 0.8.1/0.7.3), 1 Low v reseni k datu publikace. Nebylo overeno, zda oprava toho posledniho Low nalezu je soucasti 0.9.0 (aktualni verze v tomto spiku) - zdroj: blog.phnx.im/openmls-independent-security-audit/, datum overeni zde 2026-09-17. |
| OpenMLS licence | Nizke | MIT (openmls, openmls_rust_crypto, openmls_basic_credential, openmls_traits - vse license: MIT dle cargo info, overeno 2026-09-17). Bez copyleft, zadny konflikt s uzavrenym/komercnim produktem. |
| mls-rs (alternativa) - bez 3rd-party auditu | Stredni | cargo info mls-rs -> 0.56.0, Apache-2.0 OR MIT, aktivne vyvijeny (AWS Labs). Web zdroje k 2026-09-17 uvadi "100% RFC 9420 conformance" a testovaci vektory, ale zadny zverejneny nezavisly bezpecnostni audit (na rozdil od OpenMLS). Realne nasazeni: vendorovano v Mozilla comm-central (Thunderbird) dle searchfox.org nalezu - signal zralosti, ne nahrada auditu. |
| Threaded WASM => COOP/COEP | Stredni-vysoke | Viz 3.3-3.4. Netrivialni provozni zmena, riziko regrese pro cross-origin subresources. Zmirneni: wasm-bindgen fallback bez threads (nebyl end-to-end vyzkousen, ale 2. dokazuje, ze jadro jde prelozit i bez +atomics). |
| add_member roste s velikosti skupiny | Nizke | 4. - 250clenska skupina "postavena po jednom" ~1 s. Jednorazovy naklad pri zakladani, ne per-message. Batch-add API existuje (add_members bere slice KeyPackages) - nebylo v tomto spiku mereno, ale evidentne resitelne. |
| iOS/macOS nebylo mozne overit | Stredni | 3.6 - NOT_RUN, ne UNSUPPORTED. Kombinuje se s existujicim rizikem ze spec 8.1 (notification service extension pametove/casove limity) - MLS runtime pamet v iOS extension kontextu je nova neznama. |
| openmls MSRV 1.91.0 | Nizke | Aktualni stable je 1.98.1, zadny konflikt ted; sledovat pri budoucich upgradech Rust toolchainu v CI. |
| RustCrypto vs. libcrux backend | Nizke | Tento spike pouzil openmls_rust_crypto (ciste Rust implementace, RustCrypto projekt). openmls nabizi i libcrux_provider feature (formalne verifikovana kryptografie z HACL*/EverCrypt) - nezkouseno, potencialne silnejsi bezpecnostni argument pro compliance, ale nejista WASM/mobile podpora - vyzadovalo by vlastni mensi spike, pokud by na tom compliance trvala. |

---

## 9. Doporuceni

GO s vyjimkami:
1. Rust jadro nad OpenMLS funguje a uzavira KB2 (overeno testem) - bezpecne pokracovat s OpenMLS jako krypto jadrem pro krok 2, ne s mls-rs (chybi nezavisly audit) ani s vlastni kryptografii (spec to zakazuje explicitne).
2. Windows desktop a Android jsou bez vyhrad (PASS na obojim, vcetne skutecneho Flutter build pipeline pres CargoKit).
3. Vyjimka - web: nasadit az po rozhodnuti o COOP/COEP dopadu na zbytek stranky (3.4) - bud prijmout threaded-WASM cestu (FRB default) a provest separatni audit cross-origin subresources, nebo prejit na nethreadovany wasm-bindgen primo (fallback, vic rucni prace, zadna nova hlavickova zavislost). Toto rozhodnuti doporucuji udelat pred zacatkem kroku 2, ne uprostred neho.
4. Vyjimka - iOS/macOS: overit na skutecnem Apple stroji pred zavazkem; kombinuje se s jiz znamym rizikem spec 8.1 (mobil = nejvetsi riziko projektu).
5. Server implications (sekce 7) jsou zvladnutelne rozsireni dnesniho Delivery Service (KeyPackage store, epoch-aware commit ordering, Welcome delivery) - zadne z nich nevyzaduje architektonicky obrat podle 6.2 (.NET zustava, Rust zustava jen krypto knihovna na klientovi, ne na serveru).

---

## Priloha - presne prikazy a exit kody

```
# Rust jadro
cd spikes/mls/mls_core
cargo build                                                    # exit 0
cargo test --release                                           # exit 0, 1 passed
cargo build --release --target wasm32-unknown-unknown --lib    # exit 0
cargo run --release --example timing                           # exit 0

# Flutter binding
cd spikes/mls/mls_flutter
flutter_rust_bridge_codegen generate                           # exit 0
flutter build windows                                          # exit 0
flutter build apk --debug                                      # exit 0
cargo install wasm-pack --locked                                # exit 0 (jednorazove)
rustup component add rust-src --toolchain nightly-x86_64-pc-windows-msvc   # exit 0 (jednorazove)
flutter_rust_bridge_codegen build-web --release                 # exit 0
flutter build web --release                                     # exit 0
```
