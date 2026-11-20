SELECT count(*), sum(debit) AS debits, sum(credit) AS credits FROM lx.journal_lines WHERE workspace_id = '__WS__'
