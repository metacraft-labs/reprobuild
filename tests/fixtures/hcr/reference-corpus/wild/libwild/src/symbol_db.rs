// reprobuild.hcr.reference-corpus fixture: wild
// Symbol database state used by incremental link decisions.
pub struct SymbolFact {
    pub name: &'static str,
    pub address: u64,
}

pub fn has_address(symbol: &SymbolFact) -> bool {
    symbol.address != 0 && !symbol.name.is_empty()
}
