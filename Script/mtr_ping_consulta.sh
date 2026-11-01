#!/bin/bash

# =========================================================
# Diagnóstico de Rota com MTR - Script de Análise Avançada
# =========================================================
# Este script executa uma análise detalhada da rota de rede
# até um domínio ou IP informado, utilizando o comando MTR.
# Ele verifica cada hop (salto), analisando perda de pacotes,
# tempos de resposta (último, médio, melhor, pior) e variação.
# A saída é interpretada com explicações diretas para cada métrica.
# Ao final, é exibido um resumo completo com avaliação do trajeto,
# destacando possíveis perdas e latências anormais.
#
# Dependências: mtr, bc, awk
# Desenvolvido por: Juninho & ChatGPT

# Cores para saída
VERMELHO=$(tput setaf 1)
VERDE=$(tput setaf 2)
AMARELO=$(tput setaf 3)
AZUL=$(tput setaf 6)
RESET=$(tput sgr0)
NEGRITO=$(tput bold)

check_dependencies() {
  local missing=()
  for cmd in mtr bc awk; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${AMARELO}Instalando dependências: ${missing[*]}${RESET}"
    sudo apt update && sudo apt install -y "${missing[@]}"
  fi
}

clean_target() {
  local input="$1"
  input=${input#http://}
  input=${input#https://}
  input=${input%%/*}
  echo "$input"
}

run_mtr() {
  local target="$1"
  echo -e "${AZUL}${NEGRITO}Executando mtr para: $target${RESET}"
  mtr -r -c 5 "$target" > /tmp/mtr_output.txt 2>/tmp/mtr_error.txt
  if [ $? -ne 0 ]; then
    echo -e "${VERMELHO}Erro ao executar mtr:${RESET}"
    cat /tmp/mtr_error.txt
    exit 1
  fi
}

is_number() {
  [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]
}

explain_loss() {
  local loss=$1
  if is_number "$loss" && (( $(echo "$loss > 0" | bc -l) )); then
    echo -e "${VERMELHO}⚠️ Perda de pacotes detectada.${RESET}"
  else
    echo -e "${VERDE}✔ Sem perda detectada.${RESET}"
  fi
}

explain_loss_inline() {
  local loss=$1
  if is_number "$loss" && (( $(echo "$loss > 0" | bc -l) )); then
    echo -e "${AMARELO}⚠️ Perda detectada${RESET}"
  else
    echo -e "${VERDE}✔ Sem perda detectada${RESET}"
  fi
}

print_hop_info() {
  local hop="$1"
  local host="$2"
  local loss="$3"
  local sent="$4"
  local last="$5"
  local avg="$6"
  local best="$7"
  local wrst="$8"
  local stdev="$9"

  printf "\n${NEGRITO}Analisando hop %s|--: %s${RESET}\n" "$hop" "$host"
  printf "  Perda de pacotes (Loss%%): %s%% ->   %s\n" "$loss" "$(explain_loss_inline "$loss")"
  printf "  Pacotes enviados (Snt): %s\n" "$sent"
  printf "  Último tempo (Last): %s ms -> Tempo de resposta do último pacote enviado.\n" "$last"
  printf "  Tempo médio (Avg): %s ms -> Média do tempo de resposta dos pacotes.\n" "$avg"
  printf "  Melhor tempo (Best): %s ms -> Menor tempo registrado, rota ideal.\n" "$best"
  printf "  Pior tempo (Wrst): %s ms -> Maior tempo registrado, possível latência ou pico.\n" "$wrst"
  printf "  Desvio padrão (StDev): %s ms -> Variação do tempo, indica estabilidade.\n" "$stdev"
}

analyze_mtr_output() {
  echo -e "\n${AZUL}${NEGRITO}Analisando saída do MTR...${RESET}"

  local total_hops=0
  local total_loss=0
  local max_loss=0
  local hops_com_perda=0

  local hop_lines=()

  while IFS= read -r line; do
    hop_lines+=("$line")
  done < <(tail -n +2 /tmp/mtr_output.txt)

  for line in "${hop_lines[@]}"; do
    local fields=($line)
    if [ ${#fields[@]} -lt 9 ]; then
      echo -e "${VERMELHO}Linha ignorada (campos insuficientes):${RESET} $line"
      continue
    fi

    local stdev="${fields[-1]}"
    local wrst="${fields[-2]}"
    local best="${fields[-3]}"
    local avg="${fields[-4]}"
    local last="${fields[-5]}"
    local sent="${fields[-6]}"
    local loss="${fields[-7]}"
    local hop_raw="${fields[0]}"
    local hop="${hop_raw//./}"

    local host_start=1
    local host_end=$((${#fields[@]} - 8))
    local host=""
    for ((i=host_start; i<=host_end; i++)); do
      host+="${fields[i]} "
    done
    host=$(echo "$host" | sed 's/ *$//')

    if is_number "$loss"; then
      total_loss=$(echo "$total_loss + $loss" | bc)
      if (( $(echo "$loss > $max_loss" | bc -l) )); then
        max_loss=$loss
      fi
      if (( $(echo "$loss > 0" | bc -l) )); then
        ((hops_com_perda++))
      fi
    fi
    ((total_hops++))

    print_hop_info "$hop" "$host" "$loss" "$sent" "$last" "$avg" "$best" "$wrst" "$stdev"

  done

  if (( total_hops == 0 )); then
    echo -e "${VERMELHO}Nenhum hop válido encontrado na saída.${RESET}"
    exit 1
  fi

  local avg_loss=$(echo "scale=2; $total_loss / $total_hops" | bc)

  echo -e "\n${NEGRITO}Resumo da análise:${RESET}"
  echo -e "  Total de hops analisados: ${AZUL}$total_hops${RESET}"
  echo -e "  Perda média de pacotes: ${AZUL}${avg_loss}%%${RESET}"
  echo -e "  Hops com perda: ${AZUL}${hops_com_perda}${RESET}"
  echo -e "  Máxima perda detectada: ${AZUL}${max_loss}%%${RESET}"

  local diagnostico=""

  if (( hops_com_perda == 0 )); then
    diagnostico="${VERDE}✔ A rota até o destino está saudável, sem perda de pacotes.${RESET}\n${VERDE}✔ O domínio/IP analisado está OK e responsivo.${RESET}"
  elif (( hops_com_perda <= 2 && $(echo "$max_loss < 20" | bc -l) )); then
    diagnostico="${AMARELO}⚠️ Pequenas perdas detectadas em poucos hops, pode ser normal.${RESET}\n${VERDE}✔ O destino provavelmente está acessível.${RESET}"
  else
    diagnostico="${VERMELHO}❌ Perdas significativas encontradas. Verifique conectividade com o domínio/IP.${RESET}"
  fi

  echo -e "\n${NEGRITO}RESUMO FINAL:${RESET}"
  echo -e "  Domínio/IP analisado: ${AZUL}$target${RESET}"
  echo -e "  Total de hops: ${AZUL}$total_hops${RESET}"
  echo -e "  Perda média de pacotes: ${AZUL}${avg_loss}%%${RESET}"
  echo -e "  Hops com perda: ${AZUL}${hops_com_perda}${RESET}"
  echo -e "  Máxima perda detectada: ${AZUL}${max_loss}%%${RESET}"
  echo -e "\n  Diagnóstico:\n  $diagnostico"

  echo -e "\n${VERDE}Análise concluída.${RESET}\n"
}

main() {
  check_dependencies
  read -p "Digite domínio ou IP para análise: " input
  target=$(clean_target "$input")
  run_mtr "$target"
  analyze_mtr_output
}

main

