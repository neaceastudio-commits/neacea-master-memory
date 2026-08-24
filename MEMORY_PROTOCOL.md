# Memory Protocol V0.3

## Regola base

La Master Memory conserva solo informazioni esplicitamente ammesse dal flusso di acquisizione. In V0.1 non viene importato automaticamente alcun dato già presente nelle conversazioni.

## Acquisizione

| Modalità | Comportamento |
| --- | --- |
| `AUTOMATIC` | Usare solo per informazione chiaramente persistente e ammessa da una regola futura esplicita. Creare sempre fonte e versione. |
| `CONFIRM` | Proporre il salvataggio; fino alla conferma l'informazione non diventa una memoria corrente. Un record di intake può indicare che resta solo nella conversazione. |
| `NEVER_AUTO` | Non salvare automaticamente contenuto o memoria. Se serve tracciare l'esito, registrare soltanto un fingerprint e lo stato `CONVERSATION_ONLY` o `DISMISSED`, mai il contenuto. |

Ogni memoria richiede una fonte `CONVERSATION`, `DOCUMENT`, `MANUAL_ENTRY`, `SYSTEM_APPLICATION` o `IMPORT`. La fonte contiene il riferimento disponibile e non viene modificata dopo la creazione.

## Versionamento e stato

1. Una nuova informazione crea un `memory_items` e la sua `memory_versions` numero 1.
2. Una modifica non aggiorna la versione precedente: crea una nuova versione con `supersedes_version_id` verso quella precedente.
3. `memory_items.current_version_id` identifica la versione attuale. La vista interna deriva `SUPERSEDED` per tutte le versioni che non sono più correnti.
4. Le versioni possono nascere come `CURRENT`, `ARCHIVED` o `TO_VERIFY`; `SUPERSEDED` è uno stato derivato, non una riscrittura dello storico.
5. Il campo `valid_from`/`valid_to` distingue la validità temporale dalla data tecnica di registrazione.

Di conseguenza una verifica futura può classificare un'informazione come:

- presente nella Master Memory: esiste un record con stato corrente o storico;
- presente solo nella conversazione: esiste un intake `CONVERSATION_ONLY` e nessuna memoria collegata;
- obsoleta o sostituita: una versione non è il `current_version_id` ed è quindi `SUPERSEDED`.

## Sensibilità e recupero

- `PUBLIC`, `PRIVATE`, `CONFIDENTIAL` e `HIGHLY_SENSITIVE` sono valori espliciti della versione.
- Ricerca ed export escludono `HIGHLY_SENSITIVE` per default.
- Per includerlo occorre invocare intenzionalmente la RPC con `p_include_highly_sensitive = true` da una sessione autenticata proprietaria. Nessun recupero automatico deve impostare quel flag.

## Journal V0.2

Il Journal è il punto di ingresso previsto per contenuti giornalieri, conversazioni o note vocali future:

```text
Conversazione / voce
→ Journal Entry (testo originale + fonte)
→ classificazione e revisione strutturata
→ eventuale Memory Item collegato
→ versionamento
→ export / backup
```

- `original_text` viene salvato una sola volta e non può essere sovrascritto.
- Titolo, testo strutturato, dati strutturati, stato e sensibilità vivono in `journal_entry_revisions`; una correzione crea una nuova revisione.
- Le classificazioni sono multiple e versionate con la revisione: `EVENT`, `DECISION`, `PAYMENT`, `IDEA`, `PROBLEM`, `IMPRESSION`, `NEXT_ACTION`.
- `project_reference` resta compatibile con lo storico Journal; V0.3 aggiunge il dominio `projects` con relazioni UUID tipizzate.
- Una relazione `journal_memory_links` permette di passare in entrambi i sensi tra Journal e Master Memory. Il testo non viene copiato nella memoria.
- `GENERATED` indica che l'entry ha prodotto una memoria; `REFERENCED` indica un collegamento contestuale.

## Journal, Memory, Project, Timeline e Source

- **Journal** è ciò che è stato raccontato o registrato in uno specifico momento. L'originale è immutabile; la classificazione vive nelle revisioni.
- **Memory** è conoscenza consolidata, con versioni, stato, validità e fonte.
- **Project** è un contenitore organizzativo con stato (`PLANNED`, `ACTIVE`, `PAUSED`, `COMPLETED`, `ARCHIVED`), date e metadati.
- **Timeline** è la cronologia di un Project. Ogni evento punta a Journal, Memory, pagamento, Source/documento o milestone tramite relazione, senza duplicare il contenuto.
- **Source** è la provenienza: conversazione, documento, inserimento manuale, sistema/applicazione o importazione.

## Project e cronologia

Le modifiche importanti al progetto passano dalla RPC `transition_project_status` e producono sempre una riga in `project_status_history`; la situazione precedente non viene cancellata. Gli eventi della timeline sono append-only e possono rappresentare decisioni tramite un memory item di tipo `DECISION`.

Il modello è pronto per ricostruire in futuro la storia di NEACEA STUDIO attraverso le fasi `IDEA`, `DESIGN`, `FINANCING`, `LOCATION_RESEARCH`, `WORKS`, `AUTHORIZATIONS`, `EQUIPMENT_PURCHASE`, `FIT_OUT`, `OPENING`, `OPERATIONS` ed `EVOLUTION`. Queste sono solo fasi dello schema: non esiste ancora alcun progetto o dato reale.

I pagamenti sono record futuri con fonte obbligatoria, progetto opzionale e relazione separata `journal_payment_links` verso Journal. `project_sources` collega un Project a un Source/documento senza trasformare V0.3 in un document management system.

## Cancellazione

- In V0.1 non esiste cancellazione automatica o fisica delle memorie.
- L'operazione normale è `ARCHIVED`, tramite una nuova versione o un flusso esplicito futuro.
- Una cancellazione fisica richiede una procedura separata, autorizzazione esplicita, backup verificato, valutazione degli impatti e una nuova migration revisionata. Non deve essere usata come alternativa al versionamento.

## Esportazione

- JSON: `master_memory.export_master_memory_json` esporta memory item, versioni, fonti, intake record, Journal, revisioni, classificazioni, Projects, storico stati, timeline, pagamenti e relazioni. Il flag per `HIGHLY_SENSITIVE` resta esplicito.
- Markdown: `master_memory.export_master_memory_markdown` produce una rappresentazione leggibile delle stesse informazioni fondamentali, includendo Projects, timeline, pagamenti e Source.
- SQL/database: le migration Git sono lo schema portabile; un dump logico autorizzato del progetto completa l'esportazione dei dati quando sarà richiesto.
