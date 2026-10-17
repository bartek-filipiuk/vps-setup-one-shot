// Public roadmap. Mirrors ROADMAP.md in the repo root: same ids, same lanes, no dates.
import type { Lang } from "./copy";

export type LaneKey = "now" | "next" | "later" | "ideas";
export type Item = { id: string; name: string; value: string; done?: string };
export type Shipped = { date: string; text: string };

const en: { lanes: Record<LaneKey, Item[]>; shipped: Shipped[] } = {
  lanes: {
    now: [
      { id: "R02", name: "The first full run, recorded", value: "One manual run of phases 01–06, start to finish, on a fresh small Hetzner server, on video. The two real open notes settled: the domain lockout in the plan and Postgres 18 in the Coolify API reference. Results written into the README Status.", done: "The README Status says phases 01–06 ran end to end on a named Coolify version, the two [verify] notes are settled, this page links the recording." },
      { id: "R01", name: "Staged test harness", value: "On every pull request, the checks that need no server: the shell library tests, shellcheck, and a syntax check of the shell blocks in the phases. A full run on a throwaway server only on demand and before releases. A fully unattended run needs the Coolify admin registration and API token steps automated and a fresh hostname per run (Let's Encrypt limits), which depends on DNS through the API.", done: "The checks run on every pull request and one on-demand full run went green." },
      { id: "R04", name: "Off-site backups and a restore drill", value: "Database backups to any S3-compatible storage, set up during handover. A runbook that restores one database from a chosen backup.", done: "The harness backs up, destroys the database, restores it, and the data is back. (Code and fake-API tests done; not run on a server yet.)" },
      { id: "R03", name: "status.sh: one screen", value: "Server reachable, disk and memory, pending reboot, Coolify version, every app with its last deploy, days to certificate expiry, last backup and whether it worked.", done: "Every line is backed by a real check, on the test server and on a production one. (Code and fake-API tests done; not run on a server yet.)" },
      { id: "R06a", name: "Alerts that reach a phone", value: "Coolify's own notifications (app stopped, deploy failed, backup failed, server unreachable, disk usage, restart limit) sent to a Discord channel, set up during handover from one webhook URL. Status says whether alerts are on.", done: "The harness stops the app and a Discord message arrives within five minutes. (Code and fake-API tests done; not run on a server yet.)" },
    ],
    next: [
      { id: "R07", name: "Safe deploys", value: "Database dump before every deploy, the rollback point printed, a runbook that reverts to the previous image and restores the dump if needed.", done: "A broken commit is deployed, rolled back, and the app is healthy with its data. (Code and fake-API tests done; not run on a server yet.)" },
      { id: "R05", name: "DOCTOR.md: my app is down", value: "From a symptom (site down, deploy failed, 502, certificate error, server unreachable) to a fix, or to an honest \"this needs a human because\".", done: "Five symptoms broken on purpose in the harness; the runbook reaches the right fix for each. (Runbook done; fixtures not run on a server yet.)" },
      { id: "R10", name: "SERVICES.md: self-host the tools", value: "Umami, n8n, Uptime Kuma and Forgejo as one-click services, each with its own domain, HTTPS, backups and a line in status. MinIO and Plausible are not one-click on the Coolify version we test with.", done: "Three services deploy in the harness with backups verified. (Runbook and helpers done; not run on a server yet.)" },
      { id: "R06b", name: "Uptime checks with a status page", value: "Uptime Kuma as a Coolify service: an uptime check per app and a public status page. Builds on self-hosted services, which create it on its own domain.", done: "The harness stops the app, Kuma marks it down, and the status page on its own domain shows it." },
      { id: "R12", name: "Handover pack", value: "Everything a client or colleague needs to take over a project or a server: a team invite with the right role, the server summary, DNS and repo ownership, and the checklist that removes your own access.", done: "A second user, with only the pack, deploys a change. (Runbook and read-only helpers done; not run on a server yet.)" },
    ],
    later: [
      { id: "R14", name: "Upgrades", value: "Coolify, Ubuntu and Postgres major versions, each with a dump first and a check after. Status says when each is due.", done: "Coolify upgrades to the newest release and Postgres 17 to 18 with data intact. (Runbook and helpers done; not run on a server yet.)" },
      { id: "R15", name: "Rebuild from nothing", value: "New server, every database restored from off-site backups, DNS repointed, apps redeployed from git. Run on purpose every quarter.", done: "The rebuilt server passes every check with all data present. (Runbook and helpers done; not run on a server yet.)" },
      { id: "R16", name: "Monthly checkup", value: "Open ports, SSH config, Docker exposure, Coolify advisories, certificate renewals, backup success rate, disk growth and this month's cost. Ends with actions, each with a runbook.", done: "No false positives on a clean setup. (Runbook and helpers done; not run on a server yet.)" },
      { id: "R18", name: "DNS through the API", value: "Cloudflare first, then the providers people ask for. The agent creates the records; the DNS click disappears.", done: "A harness run on a Cloudflare-managed domain needs no DNS click. (Code and fake-API tests done; not run on a server yet.)" },
      { id: "R19", name: "Agent packaging", value: "A Claude Code plugin with /vps-setup, /vps-status and /vps-doctor, and the same guide working in Codex and Cursor.", done: "The harness passes through the plugin and through plain markdown. (Plugin, rule and test done; not installed or run yet.)" },
      { id: "R20", name: "Providers beyond Hetzner", value: "Any Ubuntu box with your key becomes a first-class path, tested on dedicated servers, where the OS is installed through the provider's panel or API, the firewall lives on the host instead of in a cloud firewall, and there is out-of-band access. To test on: Scaleway Dedibox (critical production with a clear SLA for power and connectivity), OVHcloud Advance (automation, custom images, vRack, Anti-DDoS), Servers.com (demanding recovery: iDRAC, IPKVM, Virtual Media), Worldstream (best published value: ECC, RAID-1, iDRAC, DDoS protection).", done: "The generic path is green on one of them in addition to Hetzner." },
      { id: "R08", name: "More stacks, by fixture", value: "Static sites, Docker Compose stacks, Python, Go. Each stack has a sample app the harness deploys; without one it stays \"not supported yet\".", done: "Three stacks beyond Node are green." },
      { id: "R09", name: "Projects and clients", value: "One Coolify project per client or product, names and domains derived from it, a file listing what runs where, status grouped by project.", done: "Two projects run side by side in the harness. (Helpers, runbook changes and PROJECTS.md generation done; not run on a server yet.)" },
      { id: "R11", name: "Staging without a second server", value: "A staging branch deploys to staging.<your-domain> with its own database. Promotion is a merge to main.", done: "Push to staging changes staging; the merge changes production. (Runbook and helpers done; not run on a server yet.)" },
    ],
    ideas: [
      { id: "R21", name: "Preview deployment per pull request", value: "If Coolify's GitHub App source becomes drivable without the UI." },
      { id: "R22", name: "A status page per client", value: "From the uptime monitor in R06b, on the client's domain." },
      { id: "R23", name: "Secrets vault on your machine", value: "age or sops, with a rotation runbook." },
      { id: "R24", name: "Starter variants", value: "The same plumbing with auth and transactional mail; a worker example as a second app from the same repo." },
    ],
  },
  shipped: [
    { date: "11 October 2026", text: "Existing Hetzner server variant: pick a server you already have, attach the cloud firewall, continue as usual." },
    { date: "11 October 2026", text: "Landing in English and Polish, optional double opt-in mail updates, consent, rate limit." },
    { date: "9 October 2026", text: "Phase 05 proven on Coolify 4.3.23: private repo, Postgres 17, deploy key, webhook, push-to-deploy. This page runs on the setup it describes." },
  ],
};

const pl: typeof en = {
  lanes: {
    now: [
      { id: "R02", name: "Pierwszy pełny przebieg, nagrany", value: "Jeden ręczny przebieg faz 01–06 od początku do końca na świeżym, małym serwerze Hetznera, na wideo. Dwie prawdziwe otwarte notatki rozstrzygnięte: blokada domeny w planie i Postgres 18 w opisie API Coolify. Wyniki wpisane do sekcji Status w README.", done: "Status w README mówi, że fazy 01–06 przeszły od początku do końca na konkretnej wersji Coolify, dwie notatki [verify] są rozstrzygnięte, ta strona linkuje nagranie." },
      { id: "R01", name: "Testy etapami", value: "Przy każdym pull requeście sprawdzenia, które nie potrzebują serwera: testy biblioteki shella, shellcheck i kontrola składni bloków shella z faz. Pełny przebieg na jednorazowym serwerze tylko na żądanie i przed wydaniem. Przebieg w pełni bez człowieka wymaga zautomatyzowania rejestracji admina i tokenu API w Coolify oraz nowej nazwy hosta przy każdym przebiegu (limity Let's Encrypt), a to zależy od DNS przez API.", done: "Sprawdzenia działają przy każdym pull requeście i jeden pełny przebieg na żądanie przeszedł na zielono." },
      { id: "R04", name: "Backupy poza serwerem i ćwiczenie restore", value: "Backupy bazy do dowolnego storage zgodnego z S3, ustawiane przy przekazaniu. Runbook, który przywraca jedną bazę z wybranego backupu.", done: "Test robi backup, niszczy bazę, przywraca ją i dane wracają. (Kod i testy na udawanym API gotowe; jeszcze nieuruchomione na serwerze.)" },
      { id: "R03", name: "status.sh: jeden ekran", value: "Serwer odpowiada, dysk i pamięć, oczekujący restart, wersja Coolify, każda apka z ostatnim deployem, dni do wygaśnięcia certyfikatu, ostatni backup i czy się udał.", done: "Każda linia oparta na prawdziwym sprawdzeniu, na serwerze testowym i produkcyjnym. (Kod i testy na udawanym API gotowe; jeszcze nieuruchomione na serwerze.)" },
      { id: "R06a", name: "Alerty, które docierają na telefon", value: "Powiadomienia Coolify (apka zatrzymana, deploy padł, backup padł, serwer nie odpowiada, zajętość dysku, limit restartów) wysyłane na kanał Discorda, ustawiane przy przekazaniu z jednego adresu webhooka. Status mówi, czy alerty są włączone.", done: "Test zatrzymuje apkę i wiadomość na Discordzie przychodzi w ciągu pięciu minut. (Kod i testy na udawanym API gotowe; jeszcze nieuruchomione na serwerze.)" },
    ],
    next: [
      { id: "R07", name: "Bezpieczne deploye", value: "Dump bazy przed każdym deployem, wypisany punkt powrotu, runbook, który wraca do poprzedniego obrazu i w razie potrzeby przywraca dump.", done: "Zepsuty commit wchodzi, zostaje cofnięty, a apka działa ze swoimi danymi. (Kod i testy na udawanym API gotowe; jeszcze nieuruchomione na serwerze.)" },
      { id: "R05", name: "DOCTOR.md: moja apka nie działa", value: "Od objawu (strona nie działa, deploy padł, 502, błąd certyfikatu, serwer nie odpowiada) do naprawy albo do uczciwego „tu potrzebny człowiek, bo”.", done: "Pięć objawów wywołanych celowo w teście; runbook dochodzi do właściwej naprawy każdego. (Runbook gotowy; scenariusze jeszcze nieuruchomione na serwerze.)" },
      { id: "R10", name: "SERVICES.md: własne narzędzia jednym promptem", value: "Umami, n8n, Uptime Kuma i Forgejo jako usługi one-click, każda z własną domeną, HTTPS, backupem i linią w statusie. MinIO i Plausible nie są one-click w wersji Coolify, na której testujemy.", done: "Trzy usługi wdrożone w teście, backupy sprawdzone. (Runbook i funkcje pomocnicze gotowe; jeszcze nieuruchomione na serwerze.)" },
      { id: "R06b", name: "Monitor dostępności ze stroną statusu", value: "Uptime Kuma jako usługa w Coolify: monitor dostępności każdej apki i publiczna strona statusu. Opiera się na własnych usługach, które stawiają ją na własnej domenie.", done: "Test zatrzymuje apkę, Kuma oznacza ją jako niedostępną, a strona statusu na własnej domenie to pokazuje." },
      { id: "R12", name: "Pakiet przekazania", value: "Wszystko, czego klient albo współpracownik potrzebuje, żeby przejąć projekt lub serwer: zaproszenie do zespołu z właściwą rolą, podsumowanie serwera, własność DNS i repo, i checklista odcinająca Twój dostęp.", done: "Druga osoba, mając tylko pakiet, wdraża zmianę. (Runbook i pomocnicze funkcje tylko do odczytu gotowe; jeszcze nieuruchomione na serwerze.)" },
    ],
    later: [
      { id: "R14", name: "Aktualizacje", value: "Coolify, Ubuntu i duże wersje Postgresa, każda z dumpem przed i sprawdzeniem po. Status mówi, kiedy która jest należna.", done: "Coolify aktualizuje się do najnowszej wersji, a Postgres 17 do 18 bez utraty danych. (Runbook i funkcje pomocnicze gotowe; jeszcze nieuruchomione na serwerze.)" },
      { id: "R15", name: "Odbudowa z niczego", value: "Nowy serwer, każda baza przywrócona z backupów poza serwerem, DNS przepięty, apki wdrożone z gita. Uruchamiane celowo co kwartał.", done: "Odbudowany serwer przechodzi wszystkie sprawdzenia z kompletem danych. (Runbook i funkcje pomocnicze gotowe; jeszcze nieuruchomione na serwerze.)" },
      { id: "R16", name: "Miesięczny przegląd", value: "Otwarte porty, konfiguracja SSH, ekspozycja Dockera, ostrzeżenia Coolify, odnowienia certyfikatów, skuteczność backupów, przyrost dysku i koszt tego miesiąca. Kończy się listą działań, każde z runbookiem.", done: "Zero fałszywych alarmów na czystym setupie. (Runbook i funkcje pomocnicze gotowe; jeszcze nieuruchomione na serwerze.)" },
      { id: "R18", name: "DNS przez API", value: "Najpierw Cloudflare, potem dostawcy, o których ludzie poproszą. Agent tworzy rekordy; klik w DNS znika.", done: "Przebieg testu na domenie w Cloudflare nie wymaga kliku w DNS. (Kod i testy na udawanym API gotowe; jeszcze nieuruchomione na serwerze.)" },
      { id: "R19", name: "Pakowanie dla agentów", value: "Plugin Claude Code z /vps-setup, /vps-status i /vps-doctor oraz ta sama instrukcja działająca w Codex i Cursor.", done: "Test przechodzi przez plugin i przez zwykły markdown. (Plugin, reguła i test gotowe; jeszcze niezainstalowane i nieuruchomione.)" },
      { id: "R20", name: "Dostawcy poza Hetznerem", value: "Dowolna maszyna z Ubuntu i Twoim kluczem jako pełnoprawna ścieżka, sprawdzona na serwerach dedykowanych, gdzie system instaluje się przez panel albo API dostawcy, firewall stoi na samym serwerze zamiast w chmurze, a do maszyny jest dostęp poza siecią (out-of-band). Do sprawdzenia: Scaleway Dedibox (krytyczna produkcja z jasnym SLA na zasilanie i łącze), OVHcloud Advance (automatyzacja, własne obrazy, vRack, Anti-DDoS), Servers.com (wymagające odzyskiwanie: iDRAC, IPKVM, Virtual Media), Worldstream (najlepsza opublikowana relacja ceny do jakości: ECC, RAID-1, iDRAC, ochrona DDoS).", done: "Ogólna ścieżka działa na zielono u jednego z nich, oprócz Hetznera." },
      { id: "R08", name: "Więcej stacków, każdy z aplikacją testową", value: "Strony statyczne, stacki Docker Compose, Python, Go. Każdy stack ma przykładową apkę, którą test wdraża; bez niej zostaje „jeszcze niewspierany”.", done: "Trzy stacki poza Node na zielono." },
      { id: "R09", name: "Projekty i klienci", value: "Jeden projekt Coolify na klienta albo produkt, nazwy i domeny wyprowadzone z niego, plik z listą co gdzie działa, status pogrupowany po projektach.", done: "Dwa projekty działają obok siebie w teście. (Funkcje pomocnicze, zmiany w runbookach i generowanie PROJECTS.md gotowe; jeszcze nieuruchomione na serwerze.)" },
      { id: "R11", name: "Staging bez drugiego serwera", value: "Gałąź staging wdraża się na staging.<twoja-domena> z własną bazą. Promocja to merge do main.", done: "Push na staging zmienia staging; merge zmienia produkcję. (Runbook i funkcje pomocnicze gotowe; jeszcze nieuruchomione na serwerze.)" },
    ],
    ideas: [
      { id: "R21", name: "Podgląd dla każdego pull requesta", value: "Jeśli źródło GitHub App w Coolify da się ustawić bez klikania." },
      { id: "R22", name: "Strona statusu dla każdego klienta", value: "Z monitora dostępności z R06b, na domenie klienta." },
      { id: "R23", name: "Sejf na sekrety na Twoim komputerze", value: "age albo sops, z runbookiem rotacji." },
      { id: "R24", name: "Warianty startera", value: "Ta sama instalacja z logowaniem i mailem transakcyjnym; przykład workera jako druga apka z tego samego repo." },
    ],
  },
  shipped: [
    { date: "11 października 2026", text: "Wariant z istniejącym serwerem Hetznera: wskazujesz serwer, który już masz, firewall chmurowy zostaje podpięty, dalej jak zwykle." },
    { date: "11 października 2026", text: "Landing po angielsku i polsku, opcjonalne aktualizacje mailem z podwójnym potwierdzeniem, zgoda, limit prób." },
    { date: "9 października 2026", text: "Faza 05 sprawdzona na Coolify 4.3.23: prywatne repo, Postgres 17, klucz deploy, webhook, deploy po pushu. Ta strona działa na setupie, który opisuje." },
  ],
};

export const roadmap: Record<Lang, typeof en> = { en, pl };
