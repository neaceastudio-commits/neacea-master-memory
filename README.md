# NEACEA MASTER MEMORY

Infrastruttura indipendente per una memoria personale persistente, versionata e interrogabile. V0.2 usa un progetto Supabase dedicato, include il Journal e non contiene alcun dato personale importato.

## Stato V0.2

- Database: PostgreSQL in un progetto Supabase dedicato `neacea-master-memory`.
- Schema privato: `master_memory`, non esposto come schema Data API.
- Versionamento: ogni modifica crea una nuova `memory_versions`; le versioni e le fonti sono append-only.
- Ricerca: full-text search PostgreSQL su titolo e contenuto, con indice GIN.
- Journal: testo originale immutabile, revisioni strutturate append-only, classificazioni e collegamenti bidirezionali ai memory item.
- Export: RPC JSON completa e Markdown leggibile; le migration Git restano la base per un backup SQL portabile.
- Sicurezza: RLS su tutte le tabelle, nessun privilegio diretto per `anon` o `authenticated`, RPC limitate ad utenti autenticati e proprietari dei dati.
- Sensibilità: le ricerche e l'export escludono `HIGHLY_SENSITIVE` per impostazione predefinita; l'inclusione richiede il flag esplicito dedicato.

## Struttura

```text
supabase/migrations/   Schema SQL versionato e applicato a Supabase
types/database.ts      Tipi TypeScript coerenti con lo schema V0.1
BACKUP_E_RIPRISTINO.md Procedura di backup e ripristino
MEMORY_PROTOCOL.md     Regole di acquisizione, versionamento e cancellazione
```

## Modello dati

| Oggetto | Responsabilità |
| --- | --- |
| `memory_sources` | Provenienza: conversazione, documento, inserimento manuale, sistema/applicazione o importazione. |
| `memory_items` | Identità stabile di una memoria e puntatore alla versione corrente. |
| `memory_versions` | Snapshot immutabili di categoria, tipo, contenuto, stato, sensibilità, affidabilità, validità e fonte. |
| `memory_intake_records` | Tracciamento minimo di presenza nella Master Memory o solo in conversazione mediante fingerprint, senza dover salvare contenuto non autorizzato. |
| `journal_entries` | Testo originale, fonte, data/ora, progetto opzionale e puntatore alla revisione strutturata corrente. |
| `journal_entry_revisions` | Titolo, testo/dati strutturati, stato e sensibilità; ogni revisione conserva la precedente. |
| `journal_revision_classifications` | Classificazioni `EVENT`, `DECISION`, `PAYMENT`, `IDEA`, `PROBLEM`, `IMPRESSION`, `NEXT_ACTION`. |
| `journal_memory_links` | Collegamenti `GENERATED` o `REFERENCED` fra Journal e memory item, senza duplicare il contenuto. |

Le categorie sono testuali e flessibili; il tipo è uno fra `FACT`, `PREFERENCE`, `DECISION`, `EVENT`, `PROJECT_STATE`, `PROCEDURE`, `GOAL` e `NOTE`.

## Operatività

Le migration sono la fonte di verità dello schema. Gli export completi sono disponibili tramite `export_master_memory_json` e `export_master_memory_markdown`; `HIGHLY_SENSITIVE` richiede sempre il flag esplicito. Non inserire nel repository password, service-role key, token o URL con credenziali. Per il comportamento operativo leggere [MEMORY_PROTOCOL.md](MEMORY_PROTOCOL.md) e [BACKUP_E_RIPRISTINO.md](BACKUP_E_RIPRISTINO.md).
