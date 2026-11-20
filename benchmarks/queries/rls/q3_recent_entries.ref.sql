SELECT id, entry_date, description FROM lx.journal_entries WHERE workspace_id = '__WS__' ORDER BY entry_date DESC, seq DESC LIMIT 50
