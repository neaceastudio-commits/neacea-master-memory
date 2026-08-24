# Backup e ripristino

## Principi V0.1

- Le migration in `supabase/migrations/` sono la fonte di verità dello schema e devono essere versionate con Git.
- I dati operativi restano nel progetto Supabase dedicato `neacea-master-memory`; non vengono copiati in altri repository NEACEA.
- Nessuna chiave, password, connection string o export contenente dati personali viene salvato nel repository.
- Gli export di dati sono operazioni deliberate: la funzione `master_memory.export_memory_json(false)` esclude `HIGHLY_SENSITIVE` per impostazione predefinita.

## Backup

1. Verificare nel dashboard Supabase del progetto dedicato che i backup gestiti siano attivi e compatibili con gli obiettivi di conservazione desiderati.
2. Conservare il repository Git con la history completa delle migration, incluso il commit che le ha applicate.
3. Per un export logico dei contenuti, eseguire una procedura autenticata che richiami l'export JSON e salvarne l'output solo in un archivio cifrato autorizzato.
4. L'export Markdown futuro deriva dallo stesso set di record JSON: ogni record deve includere identificativo, versione, stato, sensibilità, fonte e contenuto. Non è previsto alcun export automatico.

## Ripristino

1. Identificare il punto di ripristino e verificare il progetto Supabase di destinazione: deve essere `neacea-master-memory`, mai un altro progetto NEACEA.
2. Ripristinare prima in un ambiente isolato o in un branch database, quando disponibile, e validare schema, RLS e conteggi.
3. Per ricostruire lo schema da zero, applicare le migration Git nell'ordine dei timestamp.
4. Per ricostruire i dati, importare solo un export autorizzato e verificato, preservando `id`, `memory_id`, `version`, fonti e riferimenti di successione.
5. Un ripristino sul progetto principale che sovrascrive dati richiede una conferma esplicita separata.

## Verifiche dopo un ripristino

- Controllare che tutte le tabelle nello schema `master_memory` abbiano RLS attivo.
- Verificare l'assenza di privilegi diretti per `anon` e che le RPC richiedano un utente autenticato.
- Verificare che la ricerca e l'export escludano `HIGHLY_SENSITIVE` senza un flag esplicito.
- Eseguire gli advisor Supabase di sicurezza e performance prima di dichiarare completo il ripristino.
