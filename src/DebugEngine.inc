{$IF DEFINED (CPUX86)}
  {$IFNDEF CPU32BITS}
    {$DEFINE CPU32BITS}
  {$ENDIF !CPU32BITS}
  {$DEFINE STACK_BASED_EXCEPTIONS}
{$ELSEIF DEFINED (CPUX64)}
  {$IFNDEF CPU64BITS}
    {$DEFINE CPU64BITS}
  {$ENDIF !CPU64BITS}
  {$DEFINE TABLE_BASED_EXCEPTIONS}
{$ENDIF}

// DebugEngine faz aritmetica de ponteiro e de inteiros sem sinal em toda parte:
// com range/overflow checking do projeto (config Debug) o carregador do map
// estoura e cai silenciosamente para a tabela de exports. Desligados aqui.
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
