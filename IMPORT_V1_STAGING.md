# Import V1 — staging controllato

Questo repository prepara l'importazione storica in due passaggi separati:

```text
ChatGPT Memory
→ staging/import-v1.json
→ validazione locale
→ review umana
→ validazione finale
→ import autorizzato in Supabase
```

Questa fase non legge le conversazioni, non inserisce dati in Supabase e non crea dati di test persistenti.

## File da fornire

Il primo dataset reale deve essere fornito esattamente come:

```text
staging/import-v1.json
```

La struttura di riferimento è in [staging/import-v1.template.json](staging/import-v1.template.json); il contratto macchina è [staging/import-v1.schema.json](staging/import-v1.schema.json).

Il file `staging/import-v1.json` è escluso da Git tramite `.gitignore`: può contenere materiale reale di staging, ma non deve essere committato.

## Formato

Il file è un unico oggetto JSON:

```json
{
  "format_version": "import-v1",
  "dataset_id": "identificatore-dataset",
  "generated_at": "2026-01-01T00:00:00Z",
  "source_context": "CHATGPT_MEMORY",
  "records": []
}
```

Ogni elemento di `records` deve contenere:

- `record_id`: identificatore stabile del candidato;
- `category`: area funzionale o progetto;
- `type`: `FACT`, `PREFERENCE`, `DECISION`, `EVENT`, `PROJECT_STATE`, `PROCEDURE`, `GOAL` o `NOTE`;
- `title` e `content`;
- `status`: `CURRENT`, `ARCHIVED` o `TO_VERIFY`;
- `confidence`: numero da `0` a `100`;
- `sensitivity`: `PUBLIC`, `PRIVATE` o `CONFIDENTIAL`;
- `source`: oggetto con `type`, `label` e `reference`;
- `valid_from` e `valid_to`: data ISO oppure datetime ISO con timezone, o `null`;
- `project`: nome/riferimento del progetto oppure `null`;
- `notes`: note per la review, senza segreti;
- `import_action`: `IMPORT`, `REVIEW`, `SKIP` o `SUPERSEDE`;
- `supersedes`: `record_id`/riferimento precedente quando `import_action` è `SUPERSEDE`, altrimenti `null`.

È ammesso anche `metadata` come oggetto JSON opzionale. Non usare `status: SUPERSEDED`: nel database è uno stato derivato; per sostituire una memoria usare `import_action: SUPERSEDE` e indicare il riferimento in `supersedes`.

## Regole di sicurezza

- Non inserire password, API key, token, chiavi private, numeri di carta, IBAN o credenziali.
- `HIGHLY_SENSITIVE` è rifiutato dal validator e non deve essere incluso nel dataset.
- Non inserire dati sanitari, dati di pazienti/clienti o dati personali di terzi.
- Decisioni consolidate devono usare `type: DECISION`, non `FACT`, `NOTE` o `GOAL`.
- Un'incertezza storica deve usare `status: TO_VERIFY` e normalmente `import_action: REVIEW`.
- `SKIP` mantiene il candidato fuori dal percorso di importazione.

## Validazione locale

Il validator non usa rete, Supabase o dipendenze esterne:

```bash
python3 scripts/validate_import_v1.py staging/import-v1.json
```

Un file valido produce JSON con `"valid": true` e il conteggio delle azioni. Un file non valido termina con codice diverso da zero e descrive gli errori senza tentare alcun import.

La review e l'importazione sono passaggi successivi e richiedono autorizzazione separata. Questo V1 non contiene ancora un comando di scrittura verso Supabase.
