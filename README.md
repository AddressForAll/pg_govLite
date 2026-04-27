**pg_govLite** is designed to perform basic data governance tasks in metadata management, complementing [System Catalogs](https://www.postgresql.org/docs/current/catalogs.html) and acting as a unified metadata store. It manages the Medallion architecture and *tags* for all data objects (columns, tables, schemas, functions, etc.), with [RDF](https://en.wikipedia.org/wiki/Resource_Description_Framework) semantic tags, and [governed tags](https://docs.databricks.com/aws/en/admin/governed-tags/).

![](assets/layers.png)

## Install or test

This project foresees installation on Linux, using `make` command.

* `make` show all options.
* `make all` will install all in your database (edit Makefile to set your configurations). Standard installation.
* `make dropDbTest` will DROP the test-database and install all in it. Important for developers, to avoid [Software regression](https://en.wikipedia.org/wiki/Software_regression).
