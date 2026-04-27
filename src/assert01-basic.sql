-- ---------------------------------------------------------
-- Roteiro de Testes Unitários: Framework AFA
-- Configuração: Certifique-se de que check_assertions está ON
-- SET check_assertions = on;
-- ---------------------------------------------------------

DO $do$
BEGIN

ASSERT round(pi(),3)=3.142,
  'Error: public round(float,int) not working';
ASSERT array_distinct('{10,1,1,20,10,NULL,10}'::int[])='{10,1,20}'::int[],
  'Error: public array_distinct() not working';
ASSERT array_distinct( '{10,1,1,20,10,NULL,10}'::int[], false )='{NULL,10,1,20}'::int[],
  'Error2: public array_distinct() not working';
ASSERT array_distinct_sort('{10,1,20,2,3,NULL,10,500,5}'::int[])='{1,2,3,5,10,20,500}'::int[],
  'Error: public array_distinct_sort() not working';
ASSERT array_distinct_sort('{NULL}'::int[]) IS NULL,
  'Error2: public array_distinct_sort() not working';
ASSERT array_distinct_sort( '{NULL}'::int[], false ) = '{NULL}'::int[],
  'Error3: public array_distinct_sort() not working';

END $do$;

/* old asserts
DO $$
DECLARE
    v_status text;
    v_exists boolean;
BEGIN
    -- 1. TESTES DE LÓGICA DE NOMENCLATURA (Regex)
    ASSERT fw_cat.schema_name_validate('schema_comum') IS NULL,
           'Erro: schema_comum não deveria ser medalhão';

    ASSERT fw_cat.schema_name_validate('projeto_silver') = 'silver',
           'Erro: projeto_silver deveria ser identificado como silver';

    -- 2. TESTES DE UPSERT MANUAL
    -- nome valido: gold no final (padrao _(bronze|silver|gold)$)
    v_status := fw_cat.medallion_upsert('teste_gold');
    ASSERT v_status LIKE 'SUCESSO%',
           'Erro no upsert de teste_gold: ' || v_status;

    -- nome invalido: gold no meio nao e reconhecido pelo padrao medalhao
    v_status := fw_cat.medallion_upsert('invalido_sem_tag');
    ASSERT v_status LIKE 'ERRO%',
           'Erro: O sistema deveria ter barrado o schema invalido_sem_tag';

    -- 3. TESTES DE AUTOMAÇÃO (EVENT TRIGGERS)
    -- Simula criação física de um schema
    CREATE SCHEMA IF NOT EXISTS auto_bronze;

    SELECT EXISTS (
        SELECT 1 FROM fw_cat.medallion
        WHERE f_table_schema = 'auto_bronze' AND is_active = true
    ) INTO v_exists;

    ASSERT v_exists, 'Erro: Event Trigger falhou ao registrar auto_bronze como ativo';

    -- Simula remoção física do schema
    DROP SCHEMA auto_bronze;

    SELECT EXISTS (
        SELECT 1 FROM fw_cat.medallion
        WHERE f_table_schema = 'auto_bronze' AND is_active = false
    ) INTO v_exists;

    ASSERT v_exists, 'Erro: Event Trigger falhou ao marcar auto_bronze como inativo (is_active=false)';

    -- 4. TESTES DE NORMALIZAÇÃO DE TAGS
    -- (Assumindo que as funções de tags já foram migradas para o core)
    ASSERT fw_cat.govtags_normalize(ARRAY['cpF', 'cnpj:123', 'XpTo']) = ARRAY['CNPJ:123', 'CPF'],
           'Erro na normalização: Resultado inesperado para tags governadas/especializadas';

    RAISE NOTICE '>>>> TODOS OS TESTES PASSARAM COM SUCESSO (ASSERTs OK) <<<<';
END $$;
*/
