#!/usr/bin/env bash
# Download the open data used by the content build into data/raw/ (about 75 MB).
set -euo pipefail
cd "$(dirname "$0")/../data" && mkdir -p raw/jlpt && cd raw
T=https://downloads.tatoeba.org/exports
for f in jpn_sentences_detailed.tsv.bz2 jpn-eng_links.tsv.bz2 jpn-rus_links.tsv.bz2 jpn_tags.tsv.bz2; do
  curl -sSfo "$f" "$T/per_language/jpn/$f"; done
curl -sSfo eng_sentences.tsv.bz2 "$T/per_language/eng/eng_sentences.tsv.bz2"
curl -sSfo rus_sentences.tsv.bz2 "$T/per_language/rus/rus_sentences.tsv.bz2"
curl -sSfo JMdict.gz http://ftp.edrdg.org/pub/Nihongo/JMdict.gz
curl -sSfo kanjidic2.xml.gz http://www.edrdg.org/kanjidic/kanjidic2.xml.gz
curl -sSfo kradzip.zip http://ftp.edrdg.org/pub/Nihongo/kradzip.zip && unzip -oq kradzip.zip -d krad
for n in 1 2 3 4 5; do
  curl -sSfo "jlpt/vocab_n$n.csv" "https://raw.githubusercontent.com/stephenmk/yomitan-jlpt-vocab/main/original_data/n$n.csv"; done
curl -sSfo jlpt/kanji-data.json https://raw.githubusercontent.com/davidluzgouveia/kanji-data/master/kanji.json
echo "data/raw ready"
