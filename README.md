# Household Budget

Monthly household budget app for two people: combined salary per cut-off, daily spends,
dues checklist, debts, goals, QR wallet, side income, who-owes-whom, month review and
health & insurance. Installable on iPhone, Android and tablets.

- Front end: static files (`index.html`), hosted on Vercel. No build step.
- Back end: Supabase (auth + Postgres). Schema and security rules: `supabase/schema.sql`.
- Privacy: each person signs in with their own account. Personal spends and goals are stored
  in a private record that only its owner can read (enforced by row-level security).

## Deploy
Vercel imports this repo as a static site (Framework: Other, no build command).
Supabase connection details live in `config.js`.

Live app: https://household-budget-respiratoria.vercel.app
