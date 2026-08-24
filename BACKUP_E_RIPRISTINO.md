# Backup e ripristino

## Principi V0.3

- Le migration in `supabase/migrations/` sono la fonte di verità dello schema e devono essere versionate con Git.
- I dati operativi restano nel progetto Supabase dedicato `neacea-master-memory`; non vengono copiati in altri repository NEACEA.
- Nessuna chiave, password, connection string o export contenente dati personali viene salvato nel repository.
- Gli export di dati sono operazioni deliberate: le funzioni `master_memory.export_master_memory_json(false)` e `master_memory.export_master_memory_markdown(false)` escludono `HIGHLY_SENSITIVE` per impostazione predefinita.

## Backup

1. Verificare nel dashboard Supabase del progetto dedicato che i backup gestiti siano attivi e compatibili con gli obiettivi di conservazione desiderati.
2. Conservare il repository Git con la history completa delle migration, incluso il commit che le ha applicate.
3. Per un export logico completo, eseguire una procedura autenticata che richiami `master_memory.export_master_memory_json(false)` e salvarne l'output solo in un archivio cifrato autorizzato. Include Memory, Journal, Projects, storico stati, timeline, pagamenti, Source e relazioni.
4. Per una copia leggibile, usare l'export Markdown con lo stesso criterio esplicito di sensibilità.
5. Per portabilità fuori da Supabase conservare insieme: migration Git, export JSON completo autorizzato e, se necessario, un dump SQL/database eseguito con credenziali gestite fuori dal repository.

## Ripristino

1. Identificare il punto di ripristino e verificare il progetto Supabase di destinazione: deve essere `neacea-master-memory`, mai un altro progetto NEACEA.
2. Ripristinare prima in un ambiente isolato o in un branch database, quando disponibile, e validare schema, RLS e conteggi.
3. Per ricostruire lo schema da zero, applicare le migration Git nell'ordine dei timestamp.
4. Per ricostruire i dati, importare solo un export autorizzato e verificato, preservando `id`, `memory_id`, `version`, fonti, Journal, revisioni, classificazioni, Projects, storico stati, timeline, pagamenti e riferimenti di successione.
5. Un ripristino sul progetto principale che sovrascrive dati richiede una conferma esplicita separata.

## Verifiche dopo un ripristino

- Controllare che tutte le tabelle nello schema `master_memory` abbiano RLS attivo.
- Verificare l'assenza di privilegi diretti per `anon` e che le RPC richiedano un utente autenticato.
- Verificare che la ricerca e l'export escludano `HIGHLY_SENSITIVE` senza un flag esplicito.
- Eseguire gli advisor Supabase di sicurezza e performance prima di dichiarare completo il ripristino.

## Portabilità

Per spostare la memoria su un'altra infrastruttura, conservare insieme migration Git, JSON completo autorizzato e Markdown. Le relazioni sono espresse tramite UUID e i dati del Project non dipendono esclusivamente da Supabase. Un dump SQL/database può essere aggiunto quando sarà richiesta una copia fisica PostgreSQL.
