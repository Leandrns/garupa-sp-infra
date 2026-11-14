# Dados de entrada

`risco_celula.csv`: tabela de risco gerada pelo modelo de ML (repositório `garupa-sp-ml`, arquivo `saida/risco_celula.csv`).

O `02_app.sh` copia este arquivo para `/opt/garupa/dados/` (dono root, grupo garupa, permissão 0640) e roda o `carregar-risco` da API. Sem o arquivo, a carga é pulada com um aviso e as consultas de risco voltam vazias.

Para atualizar: copie a versão nova do repositório de ML para esta pasta e rode `sudo ./02_app.sh`.

O arquivo não tem dado pessoal: é o risco agregado por célula do mapa.
