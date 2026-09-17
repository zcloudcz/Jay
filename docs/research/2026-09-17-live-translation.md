# Jay — živý překlad hovorů (research)

Stav k 2026-09-17. Zdroje ověřené na webu jsou odkázané; co ověřit nešlo, je označeno **[neověřeno]**. Žádný kód, žádné měření na zařízeních — jen rešerše.

## 1. Shrnutí

- **Technicky to jde oběma cestami, které zadavatel zmínil:** přímý překlad řeč→řeč (jeden model) i kaskáda přepis → překlad → hlas. Přímé modely s češtinou dnes existují **jen v cloudu** (Google Gemini Live Translate; Azure Live Interpreter pravděpodobně). Open modely řeč→řeč češtinu neumí.
- **Hlavní konflikt je produktový, ne technický:** hovory Jay jsou E2E (DTLS-SRTP), server zvuk nevidí. Překlad proto musí běžet **na koncovém zařízení** — buď lokálním modelem, nebo tak, že klient sám pošle svůj zvuk do cloudu třetí strany. To druhé je vědomá výjimka ze slibu soukromí a musí být opt-in per hovor s jasným textem (stejný princip jako „kanály nejsou E2E“).
- **Největší technické riziko je `flutter_webrtc`:** plugin dnes neumí vydat syrový zvuk hovoru ani přijmout syntetizovaný zvuk jako odchozí stopu. Je to otevřený, nevyřešený problém v projektu pluginu (issues #632, #1609, diskuse #1742). Znamená to vlastní nativní kód per platforma.
- **Doporučení:** postupovat po stupních — (1) přeložené titulky, (2) předčítání překladu lokálně, (3) až pak případně přeložený hlas v odchozím zvuku. Stupeň 1 je pro jednoho vývojáře reálný; stupeň 3 zatím ne.

## 2. Dvě architektury

| | Přímý řeč→řeč (S2ST) | Kaskáda (ASR → MT → TTS) |
| --- | --- | --- |
| Latence | nižší, model překládá průběžně („pár sekund za mluvčím“) | součet tří kroků; typicky čeká na konec věty/úseku |
| Zachování hlasu a intonace | ano (Gemini, Azure Personal Voice, Hibiki) | ne, generický TTS hlas |
| Čeština | jen cloud | cloud i on-device |
| Vedlejší produkt | žádný text (titulky musí model vracet zvlášť) | přepis + překlad jako text = titulky zdarma |
| Laditelnost | černá skříňka | každý krok vyměnitelný, chyby dohledatelné |
| On-device | pro CS neexistuje | proveditelné |

## 3. Cloudová API

| Služba | Typ | Čeština | Cena | Klient napřímo (ephemeral token) | Poznámka |
| --- | --- | --- | --- | --- | --- |
| **Google `gemini-3.5-live-translate-preview`** | přímý S2ST, zachovává tón a tempo | **ano — cs, sk, pl, uk, de potvrzeny v dokumentaci** | ≈ 0,037 USD/min překládaného zvuku (sekundární zdroj) | ano (v1beta) | WebSocket, vstup PCM 16 kHz po 100 ms, výstup 24 kHz; preview; jen audio vstup. [docs](https://ai.google.dev/gemini-api/docs/live-api/live-translate) |
| **OpenAI `gpt-realtime-translate`** | přímý S2ST | **ne** — výstup jen 13 jazyků (de, en, es, fr, it, pt, ru, ja, zh, ko, hi, id, vi) | 0,034 USD/min | ano, WebRTC, dobře zdokumentováno | pro CZ/SK/PL/UA nepoužitelné. [docs](https://developers.openai.com/api/docs/models/gpt-realtime-translate) |
| **Azure Live Interpreter** | přímý S2ST + Personal Voice (klon hlasu, se souhlasem) | 76 vstupních jazyků; CS pro Live Interpreter **[neověřeno]** (klasické STT cs-CZ/sk-SK/pl-PL/uk-UA potvrzeno) | nezveřejněno, Limited Access (žádost) | pro Speech SDK obecně ano | EU Data Boundary; nejlepší příběh pro firemní zákazníky. [oznámení](https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/announcing-live-interpreter-api---now-in-public-preview/4453649) |
| **DeepL Voice API / Voice-to-Voice** | kaskáda | **[neověřeno]** (textový DeepL má CS silnou) | nezveřejněno, API Pro | [neověřeno] | EU firma; až 5 cílových jazyků naráz. [tisk](https://www.deepl.com/en/press-release/deepl-unveils-real-time-spoken-translation-breaking-the-next-language-barrier-with-voice-to-voice) |
| AWS Transcribe + Translate + Polly | kaskáda DIY | ano | jednotky USD za 10min hovor | vlastní řešení | nejvíc práce, žádná výhoda |
| Soniox, Deepgram, Speechmatics, Gladia, ElevenLabs | hlavně přepis (Soniox i překlad do textu) | různě | — | — | hlas ven neřeší; ElevenLabs dubbing je souborový, ne živý |

Orientačně: 10min obousměrný hovor přes Gemini ≈ **0,4–0,75 USD** (každý směr se účtuje zvlášť). Při 100 aktivních uživatelích s 1 h překládaných hovorů měsíčně ≈ 220–450 USD/měsíc — tohle nemůže být ve Free tarifu.

## 4. On-device a open modely

- **Přímé S2ST open modely:** Kyutai **Hibiki / Hibiki-Zero** (MIT/Apache, 1B, stavěné na telefon, zachovává hlas) — jen FR/ES/PT/DE → EN. Meta **Seamless** — licence CC-BY-NC, **nekomerční**. **Qwen3-Omni** (Apache 2.0) — mluví 10 jazyky, čeština mezi nimi není. **Voxtral TTS** — nekomerční, bez CS. → Pro češtinu přímý open model **není**.
- **Kaskáda on-device — díly existují:**
  - přepis: Whisper (whisper.cpp / WhisperKit / sherpa-onnx; CS ano), NVIDIA Parakeet-TDT 0.6B v3 / Canary-1B v2 (25 evropských jazyků vč. CS; licenci ověřit na kartě modelu);
  - překlad: NLLB-200 distilled, Bergamot (modely Firefox Translations), Google ML Kit on-device, Apple Translation framework;
  - hlas: Piper `cs_CZ-jirka` (desítky MB, real-time i na Raspberry Pi 4), systémový TTS.
  - Rychlost a paměť celé kaskády na středním Androidu **[neověřeno — nutný vlastní benchmark]**.
- **Platformní API zdarma a lokálně:** iOS/macOS 26 `SpeechAnalyzer` + Translation framework + `AVSpeechSynthesizer`; Android `SpeechRecognizer` (on-device režim) + ML Kit Translate + `TextToSpeech`. Z Flutteru přes platform channel (hotový plugin pro SpeechAnalyzer nenalezen). Apple **neotevírá** svůj Live Translation pro hovory třetím stranám — nutné poskládat z dílů.
- **Web:** výchozí Web Speech API v Chrome posílá zvuk Googlu (rozpor se slibem soukromí); Chrome 139+ má volitelný on-device režim, jen Chromium. Alternativa Whisper přes WebGPU/WASM (transformers.js) — těžké, pomalý start.
- **Vlastní server s GPU** (faster-whisper + MT + Piper): jedna RTX 4090 utáhne desítky souběžných přepisů; řádově stovky USD/měsíc při běhu 24/7 **[odhad]**. Pro Jay ale stejně znamená, že zvuk opouští E2E — jen k nám místo ke Googlu. Smysl dává až pro Enterprise on-premise.

## 5. Jak to dělá konkurence

| Produkt | Kde běží | Jazyky | UX |
| --- | --- | --- | --- |
| Apple Live Translation (iOS 26) | **na zařízení** | FaceTime/Telefon 5 (en, fr, de, pt, es) — bez CS | FaceTime: titulky; Telefon: titulky + syntetický hlas protistraně |
| Samsung Galaxy AI Live Translate | **na zařízení** (jazykové balíčky) | ~20, pl a de ano, CS nenalezena | text + hlas přes hovor, funguje i nad WhatsApp/Signal na úrovni OS |
| Google Meet | cloud (Gemini) | rozšiřuje se na 70+ | přeložený hlas se zachovaným tónem, originál ztlumen; placené Workspace |
| MS Teams Interpreter | cloud | 9 jazyků hlasem, titulky ~100 | simuluje hlas mluvčího; Copilot licence 30 USD/uživatel/měsíc |
| Zoom | cloud | titulky 46, hlas 5 (beta) | placený doplněk |
| WhatsApp | na zařízení | 6–21 | **jen textové zprávy**, hovory ne |

Závěr: privacy-first hráči (Apple, Samsung, WhatsApp) překládají **na zařízení** a češtinu v hovorech **nemá nikdo z nich**. E2E messenger s živým překladem hovorů do češtiny by byl reálná diferenciace — a zároveň důvod, proč to nikdo nemá: je to těžké.

## 6. Co to znamená pro Jay

**Kde v architektuře překlad sedí:** vždy u **posluchače nebo mluvčího na zařízení**, nikdy na serveru. Dvě varianty:

- *Překlad u posluchače* (doporučeno): moje zařízení vezme příchozí zvuk protistrany, přeloží a ukáže/přehraje mně. Protistrana nemusí nic instalovat ani povolovat, ale **její hlas** jde do mého překladače → pokud je cloudový, musí o tom protistrana vědět (indikátor „protistrana používá cloudový překlad“ přes signalizaci, možnost odmítnout).
- *Překlad u mluvčího:* moje zařízení přeloží můj hlas a pošle do hovoru překlad. Čistší z pohledu souhlasu (každý rozhoduje o svém hlasu), ale vyžaduje vložení syntetického zvuku do odchozí WebRTC stopy — přesně to, co `flutter_webrtc` neumí.

**Stupně (každý samostatně použitelný):**

| Stupeň | Co uživatel dostane | Technicky | Proveditelnost |
| --- | --- | --- | --- |
| 0 | Překlad **textových zpráv** na zařízení (jako WhatsApp) | ML Kit / Apple Translation / Bergamot na webu; žádný zvuk | snadné, plně v souladu s E2E, dobrý první krok |
| 1 | **Přeložené titulky** během hovoru | zachytit příchozí zvuk → ASR → MT → text na obrazovce | reálné; nutný nativní „odposlech“ přehrávaného zvuku per platforma |
| 2 | Titulky + **předčítání** překladu, originál ztlumen | + TTS lokálně, ducking vzdálené stopy | reálné po stupni 1; pozor na ozvěnu (TTS → mikrofon → protistrana) — nutné AEC / sluchátka |
| 3 | **Přeložený hlas v hovoru** se zachovaným hlasem | přímý S2ST (Gemini/Azure) + vlastní audio zdroj ve WebRTC | zatím nereálné pro jednoho vývojáře; čekat na podporu v `flutter_webrtc` nebo investovat do forku |

**Engine:** rozhraní `TranslationEngine` se dvěma implementacemi dává smysl až ve chvíli, kdy budou dvě — začít jednou:
- *on-device kaskáda* = výchozí, E2E slib platí beze změny, zdarma, horší kvalita a latence;
- *cloud (Gemini Live Translate)* = volitelné, placený tarif (Team/Business), výslovný souhlas, indikátor v hovoru, klient se připojuje napřímo ephemeral tokenem vydaným naším API (vzor už máme: `/turn/credentials`). Zvuk nejde přes náš server, ale jde ke Googlu.

**Známé problémy kvality** (platí pro všechny enginy): kompromis latence × přesnost; němčina se slovesem na konci věty nutí model hádat nebo čekat (doloženo v literatuře o wait-k); vlastní jména, skákání do řeči a střídání mluvčích **[z obecné znalosti, nezdrojováno]**.

## 7. Navržený další krok

Před jakýmkoli plánem udělat **dva levné spiky** (každý 1–2 dny), protože rozhodují o všem ostatním:

1. **Audio tap:** dostat syrové PCM příchozí stopy z `flutter_webrtc` na Androidu a na webu (AudioWorklet / nativní AudioTrack sink). Bez toho neexistuje ani stupeň 1.
2. **Kvalita a latence:** nahrát 5 min českého a německého hovoru a prohnat (a) Gemini Live Translate, (b) Whisper-small + ML Kit na středním Androidu. Porovnat zpoždění a srozumitelnost. Ověřit skutečnou cenu za minutu.

Stupeň 0 (překlad zpráv) je na spicích nezávislý a dá se naplánovat hned.

## 8. Co zůstalo neověřeno

Čeština v Azure Live Interpreter a DeepL Voice; ceny Azure a DeepL; latence všech cloudových služeb v číslech; výkon on-device kaskády na telefonech; licence NVIDIA modelů; EU rezidence dat pro Gemini Live (pro OpenAI Realtime je doloženo, že EU rezidence **není** plná).

## Zdroje

Google: <https://ai.google.dev/gemini-api/docs/live-api/live-translate>, <https://blog.google/innovation-and-ai/models-and-research/gemini-models/gemini-live-3-5-translate/>, <https://ai.google.dev/gemini-api/docs/pricing> · OpenAI: <https://developers.openai.com/api/docs/models/gpt-realtime-translate>, <https://developers.openai.com/api/docs/guides/voice-webrtc>, <https://help.openai.com/en/articles/10503543-data-residency-for-the-openai-api> · Azure: <https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/announcing-live-interpreter-api---now-in-public-preview/4453649>, <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-support> · DeepL: <https://www.deepl.com/en/press-release/deepl_launches_voice_api_for_real_time_speech_transcription_and_translation> · Kyutai: <https://github.com/kyutai-labs/hibiki>, <https://kyutai.org/blog/2026-02-12-hibiki-zero/> · Meta licence: <https://github.com/facebookresearch/seamless_communication/issues/297> · Qwen: <https://github.com/QwenLM/Qwen3-Omni> · NVIDIA: <https://huggingface.co/nvidia/canary-1b-v2>, <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3> · Piper CS: <https://huggingface.co/Thomcles/Piper-TTS-Czech>, <https://k2-fsa.github.io/sherpa/onnx/tts/piper.html> · Apple: <https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app>, <https://support.apple.com/guide/iphone/translate-messages-calls-and-conversations-iph22b72984d/26/ios/26> · Chrome on-device speech: <https://medium.com/@roman_fedyskyi/on-device-speech-uis-in-chrome-139-4b9f0397b9c9> · flutter_webrtc: <https://github.com/flutter-webrtc/flutter-webrtc/discussions/1742>, <https://github.com/flutter-webrtc/flutter-webrtc/issues/632>, <https://github.com/flutter-webrtc/flutter-webrtc/issues/1609> · Konkurence: <https://workspaceupdates.googleblog.com/2026/02/speech-translation-meet-ga.html>, <https://www.sammobile.com/samsung/galaxy-ai/live-translate/>, <https://blog.whatsapp.com/introducing-message-translations>
