# Memory Protocol V0.1

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

## Cancellazione

- In V0.1 non esiste cancellazione automatica o fisica delle memorie.
- L'operazione normale è `ARCHIVED`, tramite una nuova versione o un flusso esplicito futuro.
- Una cancellazione fisica richiede una procedura separata, autorizzazione esplicita, backup verificato, valutazione degli impatti e una nuova migration revisionata. Non deve essere usata come alternativa al versionamento.

## Esportazione

- JSON: la RPC `master_memory.export_memory_json` restituisce tutte le versioni, fonte e metadati dell'utente autenticato; il flag per `HIGHLY_SENSITIVE` resta esplicito.
- Markdown: un esportatore futuro trasformerà il JSON in sezioni per memoria e versione, mantenendo id, stato, sensibilità, provenienza e date. Non sarà introdotto senza una richiesta dedicata.
