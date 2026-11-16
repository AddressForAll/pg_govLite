-- Install only in the disposable PostgreSQL instance running the native tests.
ALTER TABLE gvlt.installation ADD COLUMN upgrade_probe boolean NOT NULL DEFAULT true;
