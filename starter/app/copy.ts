// Every visible string, per language. Add a language: copy it, translate it, add a route group.
export type Lang = "en" | "pl";
export type Status = "joined" | "confirm" | "invalid" | "consent" | "busy" | "failed";

export const copy = {
  en: {
    path: "/",
    other: { lang: "pl", label: "Polski", short: "PL", path: "/pl" },
    title: "vps-setup-one-shot — One command. Your own deploy server.",
    description:
      "Paste one line into your terminal. Your AI coding agent sets up a Hetzner VPS with Coolify, HTTPS, Postgres and push-to-deploy from GitHub. Open source.",
    live: "Live on this setup · build",
    h1: ["One command.", "Your own", "deploy server."],
    lede:
      "Paste one line into your terminal. Your AI coding agent takes it from there: a Hetzner VPS running Coolify with HTTPS, Postgres and push-to-deploy from GitHub, in about an hour, on a box you control.",
    commandLabel: "Setup command",
    paste: "Paste into your terminal",
    copyButton: { label: "Copy", done: "Copied", aria: "Copy command to clipboard", announced: "Command copied to clipboard" },
    note: "Open source on GitHub. Works with Claude Code; any agent that can read a file and run commands can follow the same guide.",
    repo: "Read the code",
    signup: {
      title: "Get updates by email",
      what: "A short mail when a Coolify release breaks a step and the guide gets fixed, security notes, and news about new tools from devince.dev, free and paid. Nothing else.",
      button: "Subscribe",
      sending: "Sending…",
      saving: "Saving your address…",
      consent: "I agree to receive these emails from devince.dev, including news about paid tools. One-click unsubscribe in every mail.",
      privacy: "Privacy policy",
      privacyUrl: "https://devince.dev/privacy",
      status: {
        joined: "You're on the list.",
        confirm: "Almost done. Open the mail we just sent and click the confirmation link.",
        invalid: "That doesn't look like an email address. Check for a typo.",
        consent: "Tick the box so we are allowed to email you.",
        busy: "Too many tries from your network. Wait ten minutes and try again.",
        failed: "The server didn't save that. Nothing was sent; try again in a minute.",
      } satisfies Record<Status, string>,
    },
    proof: {
      kicker: "Read from Postgres on this request",
      unknown: "unknown number of",
      people: "people signed up · served by the setup itself, build",
    },
    getTitle: "What you get",
    get: [
      { title: "The guide", body: "SETUP.md and seven short phases the agent follows. It checks the real server state instead of trusting its own memory, so you can stop at any point and resume with the same command." },
      { title: "The starter", body: "This page. Next.js 16, Postgres 17, health checks, migrations on boot, a 230 MB non-root image. Replace the copy, keep the plumbing." },
      { title: "The updates", body: "Coolify changes. When a step breaks, the guide gets fixed in the repo. Subscribers also get a short mail about it. The list is optional; the code is open either way." },
    ],
    stepsTitle: "What happens, step by step",
    stepsIntro:
      "The agent does everything that has a command or an API. You do only what has neither: accounts, payment, DNS, and typing secrets into your own terminal.",
    you: "You:",
    nothing: "Nothing.",
    steps: [
      { title: "Check your machine", what: "The agent checks git, your GitHub login and your SSH key, then asks five questions once.", you: "Answer them." },
      { title: "Rent the server", what: "A 4 GB Hetzner VPS behind a cloud firewall with only SSH and web open. About 5 EUR a month, billed hourly.", you: "Create a Hetzner API token and add two DNS records." },
      { title: "Lock it down", what: "System updates, automatic security updates, swap, and key-only SSH.", you: "Nothing." },
      { title: "Install Coolify", what: "The open-source panel that builds and runs your apps. It is never reachable from the internet before it is secured.", you: "Create the admin account through a private SSH tunnel." },
      { title: "Domain and HTTPS", what: "Coolify gets its own domain with a certificate, and the agent gets API access.", you: "Create an API token and type it into your own terminal, never into the chat." },
      { title: "Ship the starter", what: "A private GitHub repo, Postgres 17, the app on your domain, and a webhook so every push to main deploys. Each step is proven with real output.", you: "Sign up on your own page and watch the counter move." },
      { title: "Handover", what: "Backups, a one-page summary of your server, and the exact commands to tear everything down.", you: "Decide on backups." },
    ],
    trustLabel: "What you can rely on",
    trust: [
      "Secrets never pass through the chat window.",
      "Every step is verified against the real server, not the agent's memory.",
      "You can delete the server any time; billing stops.",
    ],
    footer: {
      madeBy: "Made by",
      extra: null as null | { text: string; url: string },
      health: "Health check: /api/health",
      deployed: "Deployed commit",
    },
    confirmed: {
      path: "/confirmed",
      title: "You're subscribed",
      body: "Thanks for confirming. The next mail comes when something in the guide changes, not before.",
      back: "Back to the guide",
    },
  },

  pl: {
    path: "/pl",
    other: { lang: "en", label: "English", short: "EN", path: "/" },
    title: "vps-setup-one-shot — Jedna komenda. Własny serwer do deployu.",
    description:
      "Wklej jedną linię do terminala. Twój agent AI stawia VPS na Hetznerze z Coolify, HTTPS, Postgresem i deployem po każdym pushu na GitHub. Open source.",
    live: "Działa na tym setupie · build",
    h1: ["Jedna komenda.", "Własny", "serwer do deployu."],
    lede:
      "Wklej jedną linię do terminala. Dalej prowadzi Cię agent AI: VPS na Hetznerze z Coolify, HTTPS, Postgresem i deployem po każdym pushu na GitHub. Około godziny, na serwerze, który należy do Ciebie.",
    commandLabel: "Komenda startowa",
    paste: "Wklej do terminala",
    copyButton: { label: "Kopiuj", done: "Skopiowano", aria: "Skopiuj komendę do schowka", announced: "Komenda skopiowana do schowka" },
    note: "Open source na GitHubie. Działa z Claude Code; każdy agent, który umie przeczytać plik i uruchomić komendę, przejdzie tę samą instrukcję.",
    repo: "Zobacz kod",
    signup: {
      title: "Aktualizacje mailem",
      what: "Krótki mail, gdy nowa wersja Coolify zepsuje któryś krok i instrukcja zostanie poprawiona, informacje o bezpieczeństwie oraz nowe narzędzia z devince.dev, darmowe i płatne. Nic więcej.",
      button: "Zapisz mnie",
      sending: "Wysyłam…",
      saving: "Zapisuję adres…",
      consent: "Zgadzam się na otrzymywanie tych maili od devince.dev, także o płatnych narzędziach. W każdym mailu wypiszesz się jednym kliknięciem.",
      privacy: "Polityka prywatności",
      privacyUrl: "https://devince.dev/pl/polityka-prywatnosci",
      status: {
        joined: "Jesteś na liście.",
        confirm: "Prawie gotowe. Otwórz maila, którego właśnie wysłaliśmy, i kliknij link potwierdzający.",
        invalid: "To nie wygląda na adres email. Sprawdź, czy nie ma literówki.",
        consent: "Zaznacz zgodę, inaczej nie możemy do Ciebie pisać.",
        busy: "Za dużo prób z Twojej sieci. Odczekaj dziesięć minut i spróbuj ponownie.",
        failed: "Serwer tego nie zapisał. Nic nie wysłaliśmy; spróbuj za minutę.",
      } satisfies Record<Status, string>,
    },
    proof: {
      kicker: "Odczytane z Postgresa przy tym żądaniu",
      unknown: "nieznana liczba",
      people: "zapisanych osób · serwuje to sam setup, build",
    },
    getTitle: "Co dostajesz",
    get: [
      { title: "Instrukcję", body: "SETUP.md i siedem krótkich faz, przez które prowadzi agent. Sprawdza prawdziwy stan serwera zamiast ufać własnej pamięci, więc możesz przerwać w dowolnym momencie i wrócić tą samą komendą." },
      { title: "Starter", body: "Tę stronę. Next.js 16, Postgres 17, health checki, migracje przy starcie, obraz 230 MB bez roota. Podmień teksty, zostaw instalację." },
      { title: "Aktualizacje", body: "Coolify się zmienia. Gdy któryś krok się zepsuje, instrukcja zostaje poprawiona w repo, a zapisani dostają o tym krótkiego maila. Zapis jest opcjonalny, kod jest otwarty tak czy inaczej." },
    ],
    stepsTitle: "Co się dzieje, krok po kroku",
    stepsIntro:
      "Agent robi wszystko, co ma komendę albo API. Ty robisz tylko to, co nie ma żadnego z nich: konta, płatności, DNS i wpisywanie sekretów we własnym terminalu.",
    you: "Ty:",
    nothing: "Nic.",
    steps: [
      { title: "Sprawdzenie komputera", what: "Agent sprawdza git, logowanie do GitHuba i klucz SSH, a potem raz zadaje pięć pytań.", you: "Odpowiadasz na nie." },
      { title: "Wynajęcie serwera", what: "VPS z 4 GB RAM na Hetznerze, za firewallem chmurowym, z otwartym tylko SSH i ruchem www. Około 5 EUR miesięcznie, rozliczane godzinowo.", you: "Tworzysz token API Hetznera i dodajesz dwa rekordy DNS." },
      { title: "Zabezpieczenie", what: "Aktualizacje systemu, automatyczne poprawki bezpieczeństwa, swap i SSH tylko na klucz.", you: "Nic." },
      { title: "Instalacja Coolify", what: "Panel open source, który buduje i uruchamia Twoje aplikacje. Nie jest dostępny z internetu, zanim zostanie zabezpieczony.", you: "Zakładasz konto admina przez prywatny tunel SSH." },
      { title: "Domena i HTTPS", what: "Coolify dostaje własną domenę z certyfikatem, a agent dostęp przez API.", you: "Tworzysz token API i wpisujesz go we własnym terminalu, nigdy w czacie." },
      { title: "Wdrożenie startera", what: "Prywatne repo na GitHubie, Postgres 17, aplikacja na Twojej domenie i webhook, dzięki któremu każdy push na main robi deploy. Każdy krok jest potwierdzony prawdziwym wynikiem.", you: "Zapisujesz się na własnej stronie i patrzysz, jak rośnie licznik." },
      { title: "Przekazanie", what: "Backupy, jednostronicowe podsumowanie serwera i dokładne komendy, żeby wszystko usunąć.", you: "Decydujesz o backupach." },
    ],
    trustLabel: "Na czym możesz polegać",
    trust: [
      "Sekrety nigdy nie przechodzą przez okno czatu.",
      "Każdy krok jest sprawdzany na prawdziwym serwerze, nie w pamięci agenta.",
      "Serwer usuniesz w każdej chwili, a rozliczanie się kończy.",
    ],
    footer: {
      madeBy: "Zrobione przez",
      // ponytail: dated link, remove after 2026-10-22.
      extra: { text: "Darmowa lekcja na żywo 22.10: z localhosta na własny VPS", url: "https://stronaw5dni.pl/lekcja/" } as null | { text: string; url: string },
      health: "Health check: /api/health",
      deployed: "Wdrożony commit",
    },
    confirmed: {
      path: "/pl/potwierdzone",
      title: "Zapis potwierdzony",
      body: "Dzięki za potwierdzenie. Następny mail przyjdzie, gdy coś zmieni się w instrukcji, nie wcześniej.",
      back: "Wróć do instrukcji",
    },
  },
};

export type Copy = (typeof copy)["en"];
