# DebugEngine

[English](README.md) | **Português (Brasil)**

DebugEngine é uma biblioteca Delphi de utilitários de depuração e diagnóstico: stack traces com símbolos,
hook de `Exception.StackTrace`, logs de crash, manipulação da informação de debug do Delphi (map), snapshot de
registradores da CPU, enumeração de blocos `try`, desmontagem comentada com debug info e utilitários PE.

Nasceu como o framework interno de um plugin comercial de log de erros e é compartilhada aqui na esperança de
ser útil. Todas as funções públicas estão documentadas (XML doc) no código-fonte.

- Autor original: Mahdi Safsafi — https://github.com/MahdiSafsafi/DebugEngine
- Licença: [MPL 1.1](LICENSE)

---

## Sumário

1. [Para que serve?](#para-que-serve)
2. [Compiladores e plataformas suportados](#compiladores-e-plataformas-suportados)
3. [Funcionalidades](#funcionalidades)
4. [Estrutura do repositório](#estrutura-do-repositório)
5. [Instalação](#instalação)
6. [Uso — Windows](#uso--windows)
7. [Uso — Linux](#uso--linux)
8. [Informação de debug: map, SMAP e embutir no executável](#informação-de-debug-map-smap-e-embutir-no-executável)
9. [Demos e testes](#demos-e-testes)
10. [Ferramenta de linha de comando DD](#ferramenta-de-linha-de-comando-dd)
11. [Notas sobre Delphi 13 e limitações conhecidas](#notas-sobre-delphi-13-e-limitações-conhecidas)
12. [Contribuindo](#contribuindo)

---

## Para que serve?

Usos típicos:

- **Log de erros**: fazer `E.StackTrace` devolver uma pilha legível (`endereço  módulo  unit  arquivo:linha  símbolo`)
  para toda exceção e gravar relatórios de crash completos (pilha, registradores, threads, módulos, processo e sistema).
- **Diagnóstico post-mortem**: resolver qualquer endereço de código para `unit / símbolo / linha`, obter o endereço de
  um símbolo pelo nome, calcular o tamanho de uma função.
- **Distribuir símbolos junto com o binário**: converter o `.map` do Delphi para o formato binário compacto **SMAP** e
  embuti-lo no executável (seção ou recurso), para que os traces saiam simbolizados na máquina do cliente sem enviar o map.
- **Inspeção de baixo nível** (Windows): snapshot de registradores legados/FPU/MMX/SSE/AVX, enumeração de blocos
  `try..except/finally`, desmontagem de uma função anotada com debug info, helpers de cabeçalho/seções PE.

---

## Compiladores e plataformas suportados

| Plataforma | Compilador | Status | Implementação |
|---|---|---|---|
| Windows 32 bits | `dcc32` (Delphi 10.2 … **13**) | ✅ Conjunto completo de recursos | `Source/*.pas` |
| Windows 64 bits | `dcc64` (Delphi 10.2 … **13**) | ✅ Conjunto completo de recursos | `Source/*.pas` |
| Windows 64 bits "modern" (`Win64x`) | Delphi 13 | ✅ Igual ao Win64 (compartilha compilador e RTL no Delphi 13) | `Source/*.pas` |
| Linux 64 bits | `dcclinux64` (Delphi 13) | ✅ Stack traces, símbolos, logs de crash, registradores, info do sistema | `Source/Linux/*.pas` |
| macOS / iOS / Android | — | ❌ Não suportado | — |

A implementação Windows depende de assembly inline, do formato PE, dos arquivos map do Delphi e do modelo de
exceções do Windows. A implementação Linux é Pascal puro (sem asm), construída sobre ELF, DWARF (`addr2line`) e glibc.

Verificado com Delphi 13 (Studio 37.0): Win32, Win64, Win64x e Linux64 (Ubuntu 22.04). Versões anteriores até
10.2 Tokyo devem funcionar no Windows (o projeto se originou nessa versão).

---

## Funcionalidades

### Windows (`Source/`)

| Área | O que você obtém | Unit |
|---|---|---|
| Stack trace | `StackTrace(SL)`: caminhada inteligente por EBP/RBP, reparo de cadeia quebrada, tabelas de unwind no x64, detecção de chamadas a `Halt` / métodos dinâmicos | `DebugEngine.Trace` |
| Hook de exceção | `E.StackTrace` preenchido automaticamente para toda exceção (instalado na `initialization`); endereços capturados no `raise` (x64: unwinder do SO `RtlCaptureStackBackTrace`, inclusive através do dispatcher de exceções do kernel; x86: cadeia EBP), símbolos resolvidos sob demanda, frames internos do RTL removidos; `GetExceptionStackAddresses(E)` | `DebugEngine.HookException` |
| Log de crash | `WriteCrashLog` / `BuildCrashReport`: cabeçalho estilo madExcept (data/hora, computador, usuário, SO, uptimes, CPU, memória, disco, vídeo, processo, executável, versão, compilador, crc do callstack, exceção) + seções Exception / Threads / Modules / Registers / Environment | `DebugEngine.CrashLog` |
| Debug info | `GetAddressInfo`, `GetSymbolAddress`, `GetNextSymbolAddress`, `GetSizeOfFunction`; carrega SMAP da seção, do recurso, do `.smap` ou do `.map` ao lado do módulo (convertido **em memória**, sem arquivo temporário); fallback para exports do PE | `DebugEngine.DebugInfo` |
| Map / SMAP | Parser do `.map` texto do Delphi, `ConvertMapToSMap` (opcionalmente comprimido com zlib), `TSMapReader` (independente de plataforma) | `DebugEngine.MapParser` |
| Embutir | `InsertDebugInfo` (SMAP numa seção `.SDEBUG` ou num recurso RCDATA), `RemoveDebugInfo` / `RestoreDebugInfo` (remove/restaura os dados `.debug` do próprio Delphi) | `DebugEngine.DebugUtils` |
| Blocos try | `EnumTryBlocks` (x64, a partir de `.pdata`/unwind info), `TraceTryBlocks` (x86, cadeia SEH) | `DebugEngine.Core`, `DebugEngine.Trace` |
| Registradores | `SnapshotOfLegacyRegisters`, `SnapshotOfFPURegisters`, `SnapshotOfMMXRegisters`, `SnapshotOfVectorRegisters` (XMM/YMM/ZMM), `SnapshotOfRFlagsRegister`, `SnapshotOfMXCSRRegister` com helpers tipados | `DebugEngine.AsmRegUtils` |
| Desmontador | `DisasmAndCommentFunction` (baseado no UnivDisasm), resolução de alvo de chamadas, detecção de strings Delphi | `DebugEngine.Disasm`, `Source/UnivDisasm` |
| Utilitários PE | Cabeçalhos, seções, `PeFindSection`, helpers módulo ↔ endereço | `DebugEngine.PeUtils` |

### Linux (`Source/Linux/`)

| Área | O que você obtém | Unit |
|---|---|---|
| Stack trace | `StackTrace(SL)`, `CaptureStackTrace`, `ResolveStackTrace` (`backtrace` da glibc, unwinding DWARF) | `DebugEngine.Linux.Trace` |
| Hook de exceção | `E.StackTrace` para toda exceção (instalado automaticamente); frames do RTL de `raise` removidos, endereço exato da falha preservado | `DebugEngine.Linux.HookException` |
| Log de crash | `WriteCrashLog` / `BuildCrashReport`: exceção, pilha (+frames inlined), backtrace bruto, registradores, threads, módulos, processo, sistema, fontes de debug info, mapa de memória, ambiente | `DebugEngine.Linux.HookException` |
| Sinais fatais | `InstallSignalHandlers` opcional: registra SIGSEGV/SIGBUS/SIGFPE/SIGILL/SIGABRT com os registradores **no momento da falha** (RIP, CR2, TRAPNO, ERR, `si_code` decodificado) e então encadeia ao handler do RTL | `DebugEngine.Linux.HookException` |
| Debug info | `GetAddressInfo`, `GetSymbolAddress`: `.symtab`/`.dynsym` do ELF + `dladdr` + `addr2line` (arquivo:linha, inlining) com lote por módulo e cache | `DebugEngine.Linux.DebugInfo` |
| ELF | Leitor da tabela de símbolos ELF64, demangler Itanium (`_ZN5Hello3FooEv` → `Hello.Foo`) | `DebugEngine.Linux.Elf` |
| Módulos | Enumeração via `dl_iterate_phdr`, bias de carga, endereço → módulo, `/proc/self/maps` | `DebugEngine.Linux.Modules` |
| Registradores | `SnapshotOfRegisters` (`getcontext`) e `RegistersFromContext` (`ucontext` de sinal): GP, EFLAGS decodificado, segmento, FPU, MXCSR decodificado, ST/XMM | `DebugEngine.Linux.Registers` |
| Info do sistema | Kernel, distro, CPU, memória, uptime, load; PID/TID/usuário/cmdline/VmRSS/limites; threads de `/proc/self/task`; ambiente | `DebugEngine.Linux.SysInfo` |

---

## Estrutura do repositório

```
Source/                    Units Windows (DebugEngine.*.pas) + DebugEngine.MapParser.pas (independente de plataforma)
Source/Linux/              Units Linux (DebugEngine.Linux.*.pas)
Source/UnivDisasm/         Desmontador x86/x64 usado por DebugEngine.Disasm (Windows)
Demo/                      Demo VCL (Windows) - DebugEngineDemo.dproj
Demo/Simple/               Exemplo mínimo Windows (uma exceção -> log estilo madExcept) - DebugEngineSimple.dproj
Demo/Linux/                Demo/teste de console (Linux) - DebugEngineLinuxDemo.dproj
Demo/Linux/Simple/         Exemplo mínimo Linux (uma exceção -> log) - DebugEngineLinuxSimple.dproj
Tests/Win/                 Teste de console (Win32/Win64) - DETest.dproj
Tools/Source/DD/           Ferramenta DD (map -> smap, inserir / remover debug info); binários em Tools/bin, Tools/bin64
Script/                    Geradores Perl dos helpers de RFLAGS / MXCSR
```

---

## Instalação

Não há pacote para instalar: adicione as pastas de código-fonte ao search path do seu projeto.

- **Windows**: `Source` e `Source\UnivDisasm`.
- **Linux**: `Source\Linux` (e `Source` se quiser `DebugEngine.MapParser`).

Opções de projeto que importam:

| Opção | Windows | Linux | Por quê |
|---|---|---|---|
| Linking → Map file = **Detailed** (`-GD`) | obrigatório para símbolos/linhas | recomendado | Windows: fonte do SMAP. Linux: não é usado para símbolos, inofensivo. |
| Linking → Debug information (`-V`) | opcional | **obrigatório para arquivo:linha** | Linux: DWARF consumido pelo `addr2line`. |
| Compiling → Stack frames (`-$W+`) | recomendado | — | Traces por cadeia EBP mais fiéis no Win32. |
| Otimização desligada em builds Debug | recomendado | recomendado | Frames mais fiéis. |

---

## Uso — Windows

### 1. Stack trace nas exceções (sem código)

```pascal
uses
  DebugEngine.HookException; // instala Exception.GetExceptionStackInfoProc & cia.

try
  FazAlgo;
except
  on E: Exception do
    Log(E.ClassName + ': ' + E.Message + sLineBreak + E.StackTrace);
end;
```

Saída (uma linha por frame):

```
$00AE7FF6    DETest.exe    DETest    DETest.dpr    52    +1    Level3
$00AE800A    DETest.exe    DETest    DETest.dpr    57    +1    Level2
$0090B180    DETest.exe    System.SysUtils    System.SysUtils.pas    24513    +3    Exception.RaisingException
```

### 2. Log de crash (estilo madExcept)

```pascal
uses DebugEngine.HookException, DebugEngine.CrashLog;

except
  on E: Exception do
    WriteCrashLog(E, ChangeFileExt(ParamStr(0), '.log'), [crsHeader, crsException, crsThreads, crsModules]);
end;
```

```
date/time          : 2026-08-21, 12:24:12, 157ms
computer name      : ARB
user name          : music
registered owner   : ...
operating system   : Windows 11 x64 build 26200
system language    : English
system up time     : 3 hours 30 minutes
program up time    : 0 seconds
processors         : 16x 13th Gen Intel(R) Core(TM) i7-1360P
physical memory    : 2928/16068 MB (free/total)
free disk space    : (E:) 10.49 GB
display mode       : 1920x1080, 32 bit
process id         : $71ec
allocated memory   : 6.42 MB
largest free block : 128771.88 GB
executable         : DebugEngineSimple.exe
exec. date/time    : 2026-08-21 12:24
version            :
compiled with      : Delphi 13 (Win64)
DebugEngine version: 2.0.0
callstack crc      : $63315acf, $527d4532, $976c0643
exception number   : 1
exception class    : EArgumentException
exception message  : Invalid customer id: 0

---- Exception -------------------------------------------------------------
  Class         : EArgumentException
  Message       : Invalid customer id: 0
  Address       : $00007FF6388A4155 DebugEngineSimple.exe DebugEngineSimple DebugEngineSimple.dpr:49 LoadCustomer+0x45
  Stack at raise (Exception.StackTrace):
    $00007FF6388A4155  DebugEngineSimple.exe  DebugEngineSimple  DebugEngineSimple.dpr:49  LoadCustomer+0x45
    $00007FF6388A41AE  DebugEngineSimple.exe  DebugEngineSimple  DebugEngineSimple.dpr:53  ProcessOrder+0xE
    $00007FF6388A41CA  DebugEngineSimple.exe  DebugEngineSimple  DebugEngineSimple.dpr:58  RunBatch+0xA
  Thread        : tid=31400  main thread=True
```

Seções: `crsHeader`, `crsException`, `crsThreads`, `crsModules`, `crsRegisters`, `crsEnvironment`
(`DefaultCrashReportSections` = cabeçalho + exceção, `AllCrashReportSections` = tudo).

### 3. Stack trace em qualquer lugar

```pascal
uses DebugEngine.Trace;

var SL := TStringList.Create;
StackTrace(SL);          // pilha de chamadas atual
TraceTryBlocks(SL);      // x86: blocos try ativos na pilha
```

### 4. Informação de endereço / símbolo

```pascal
uses DebugEngine.DebugInfo;

var Info: TAddressInfo;
if GetAddressInfo(@TMyForm.Button1Click, Info) then
  Writeln(Info.UnitName, ' ', Info.SymbolName, ' ', Info.SourceLocation, ':', Info.LineNumber);

P := GetSymbolAddress(0, 'System', 'MemoryManager');       // variável privada do RTL
P := GetSymbolAddress(GetModuleHandle(user32), '', 'MessageBoxA'); // API exportada
Size := GetSizeOfFunction(@MyProc);
```

Os símbolos são procurados nesta ordem: seção `.SDEBUG` → recurso `SMAP` → `MyApp.smap` (se não for mais antigo que o `.map`) →
`MyApp.map` ao lado do executável (convertido em memória, nada é gravado em disco) → tabela de exports do PE.

### 5. Registradores

```pascal
uses DebugEngine.AsmRegUtils;

var Regs: TLegacyRegisters;
SnapshotOfLegacyRegisters(Regs);      // Regs.RSP.AsRSP, Regs.RAX.AsEAX, ...
var Vec: TVectorRegisters;
SnapshotOfVectorRegisters(Vec);       // XMM/YMM/ZMM conforme suporte da CPU
Flags := SnapshotOfRFlagsRegister;    // Flags.CF, Flags.ZF, ... via record helper
```

### 6. Blocos try e desmontagem

```pascal
uses DebugEngine.Core, DebugEngine.Disasm;

EnumTryBlocks(0, MyTryCallback, nil);                      // x64: todo try/finally/except do módulo
DisasmAndCommentFunction(@MyProc, EndAddr, MyDisasmCallback, nil); // instruções + comentários (chamadas, strings, símbolos)
```

---

## Uso — Linux

### 1. Stack trace nas exceções (sem código)

```pascal
uses
  DebugEngine.Linux.HookException; // instala o hook automaticamente

except
  on E: Exception do
    Writeln(E.StackTrace);
end;
```

```
$00000000005EC120  MyApp  Myapp  MyApp.dpr:89   Myapp.RaiseAV+0x10
$00000000005EC1B7  MyApp  Myapp  MyApp.dpr:104  Myapp.TestExceptionHook+0x46
$00000000005EDB91  MyApp  Myapp  MyApp.dpr:242  Myapp.initialization+0x120
```

### 2. Log de crash completo

```pascal
except
  on E: Exception do
    WriteCrashLog(E, '/var/log/myapp.crash.log');              // DefaultCrashReportSections
    // WriteCrashLog(E, FileName, AllCrashReportSections);      // + mapa de memória + registradores vetoriais
end;
```

O relatório contém, em seções: **Exception** (classe, mensagem, inner exceptions, endereço resolvido, thread),
**Stack trace**, **Raw backtrace_symbols**, **Registers**, **Threads**, **Process**, **System**, **Debug info sources**,
**Modules** e, opcionalmente, **Memory map** e **Environment**.

### 3. Sinais fatais fora de `try/except`

```pascal
InstallSignalHandlers('/var/log/myapp.signal.log'); // SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT
```

O handler grava o relatório (no arquivo e no stderr) com os registradores **no momento da falha** e depois encadeia
ao handler anterior, de modo que o RTL do Delphi continua convertendo o sinal em `EAccessViolation` etc.

### 4. Informação de endereço / símbolo

```pascal
uses DebugEngine.Linux.DebugInfo;

var Info: TLinuxAddressInfo;
if GetAddressInfo(@MyProc, Info) then
  Writeln(Info.SymbolName, ' ', Info.SourceFile, ':', Info.LineNumber, ' ', Info.ModuleBaseName);

P := GetSymbolAddress('Myunit.MyProc');                // nome demangled ou mangled
LinuxDebugInfoOptions.UseAddr2Line := False;          // só símbolos, sem ferramenta externa
```

### 5. Registradores e info do sistema

```pascal
uses DebugEngine.Linux.Registers, DebugEngine.Linux.SysInfo;

var R: TLinuxRegisters;
SnapshotOfRegisters(R);  RegistersToStrings(R, SL);
SystemInfoToStrings(SL); ProcessInfoToStrings(SL); ThreadsToStrings(SL); ModulesToStrings(SL);
```

Requisitos e limites:
- `addr2line` (pacote `binutils`) é usado quando presente para `arquivo:linha` e frames inlined; caso contrário os
  símbolos vêm da tabela de símbolos ELF (sem linhas).
- Os stack traces cobrem apenas o thread atual (sem `ptrace`).
- Somente x86_64 (layouts de registradores seguem a glibc x86_64).
- Não disponível no Linux: enumeração de blocos try, desmontador, embutir PE/SMAP.

---

## Informação de debug: map, SMAP e embutir no executável

No Windows, o DebugEngine lê o `.map` detalhado do Delphi e o converte em **SMAP**, uma forma binária compacta
(opcionalmente comprimida com zlib) que pode ficar:

1. numa **seção** `.SDEBUG` do executável (preferido, `InsertDebugInfo(..., True)`),
2. num **recurso RCDATA** chamado `Map` do tipo `SMAP` (`InsertDebugInfo(..., False)`),
3. como `MyApp.smap` / `MyApp.map` ao lado do executável (encontrado automaticamente em tempo de execução).

```pascal
uses DebugEngine.MapParser, DebugEngine.DebugUtils;

ConvertMapToSMap('MyApp.map', [moCompress]);              // => MyApp.smap
InsertDebugInfo('MyApp.exe', 'MyApp.smap', True);        // embute numa nova seção
RemoveDebugInfo('MyApp.exe', nil);                       // remove os dados de debug do próprio Delphi (.debug), se linkados
```

O mesmo pode ser feito no build com a [ferramenta DD](#ferramenta-de-linha-de-comando-dd) como passo pós-build.

### Distribuindo um exe Release com os símbolos embutidos (sem .map ao lado do exe)

Adicione um **Post-Build event** ao projeto (funciona no IDE e no MSBuild - veja
`Demo/Simple/DebugEngineSimple.dproj` como exemplo vivo):

```
"..\..\Tools\bin\DD.exe" -c -p ".\$(Platform)\$(Config)\MyApp.map"
"..\..\Tools\bin\DD.exe" -i -s ".\$(Platform)\$(Config)\MyApp.exe" ".\$(Platform)\$(Config)\MyApp.smap"
```

O `.map` detalhado (4,5 MB no demo) vira um SMAP comprimido (~250 KB, com números de linha) dentro de
uma seção `.SDEBUG` do executável: distribua só o exe e os stack traces continuam simbolizados. Mantenha
*Linking > Debug information* ligada na configuração Release para o map ter linhas, e não distribua os
arquivos `.map`/`.smap`.


---

## Demos e testes

| Projeto | Plataforma | O que mostra |
|---|---|---|
| [Demo/Simple/DebugEngineSimple.dproj](Demo/Simple/DebugEngineSimple.dproj) | Win32 / Win64 (console) | **Comece por aqui**: uma exceção lançada alguns níveis abaixo, capturada e registrada com `WriteCrashLog` (cabeçalho estilo madExcept + Exception, Threads, Modules) no console e em `.log` |
| [Demo/DebugEngineDemo.dproj](Demo/DebugEngineDemo.dproj) | Win32 / Win64 (VCL) | Botões para cada recurso: stack trace, `E.StackTrace`, info de endereço, endereço de símbolo, registradores (via RTTI), registradores vetoriais, blocos try, desmontagem, inserir/remover SMAP |
| [Demo/Linux/Simple/DebugEngineLinuxSimple.dproj](Demo/Linux/Simple/DebugEngineLinuxSimple.dproj) | Linux64 (console) | **Comece por aqui**: uma exceção lançada alguns níveis abaixo, capturada e registrada com `WriteCrashLog` usando apenas as seções Exception, Stack trace, System, Process, Threads e Modules (console + arquivo `.log`) |
| [Demo/Linux/DebugEngineLinuxDemo.dproj](Demo/Linux/DebugEngineLinuxDemo.dproj) | Linux64 (console) | Stack trace aninhado, AV e `raise` com `E.StackTrace`, `GetAddressInfo`/`GetSymbolAddress`/demangler, registradores, sistema/processo/threads/módulos, log de crash. `-signal` força um SIGSEGV fora de `try/except`; `-noaddr2line` desativa a ferramenta externa. Código de saída = falhas |
| [Tests/Win/DETest.dproj](Tests/Win/DETest.dproj) | Win32 / Win64 (console) | Teste de toda a API Windows, incluindo embutir SMAP numa cópia do executável. Código de saída = falhas |

Execute o demo Linux numa máquina (ou WSL) com o binário compilado com `-GD -V`:

```
$ ./DebugEngineLinuxDemo
...
PASS=30 FAIL=0
$ cat DebugEngineLinuxDemo.crash.log
```

---

## Ferramenta de linha de comando DD

`Tools/bin/DD.exe` (32 bits) e `Tools/bin64/DD.exe` (64 bits), fonte em `Tools/Source/DD`.

```
DD [Comando][Opções][AppFile,MapFile]
  -c  Converte map do Delphi para smap       DD -c -p MyApp.map
  -i  Insere o smap no aplicativo            DD -i -s MyApp.exe MyApp.smap
  -r  Remove a debug info do Delphi          DD -r MyApp.exe
  -p  Comprime o smap
  -s  Insere numa nova seção quando possível (senão, recurso)
```

Evento pós-build típico: `DD -c -p "$(OUTPUTDIR)$(OUTPUTNAME).map"` e depois `DD -i -s "$(OUTPUTPATH)" "$(OUTPUTDIR)$(OUTPUTNAME).smap"`.

---

## Notas sobre Delphi 13 e limitações conhecidas

- **ASLR / base de imagem 64 bits (corrigido)**: o carregador de SMAP mapeia cada segmento do map para a seção PE de
  mesmo nome. Versões anteriores calculavam os endereços a partir do `ImageBase` em memória, que o loader do Windows
  reescreve com `DYNAMICBASE` (padrão nas versões recentes do Delphi) e que trunca a base `$140000000` das imagens de
  64 bits; a resolução de símbolos falhava silenciosamente em builds do Delphi 12/13.
- **Sem `.smap` temporário (alterado)**: carregar símbolos de um `.map` ao lado do executável não grava mais um `.smap`; a
  conversão é feita em memória. O `.smap` só é criado por `ConvertMapToSMap` / ferramenta DD, e é ignorado quando mais antigo que o `.map`.
- **Maps sem números de linha (corrigido)**: um `.map` linkado com *Debug information* desligada (Release típico) quebrava o conversor
  SMAP (tamanho inválido => falta de memória / access violations, todos os frames como `??`). Agora converte normalmente (símbolos, sem
  linhas). Uma falha ao carregar a debug info cai no fallback da tabela de exports em vez de lançar exceção.
- **Caminho do map (corrigido)**: o `.map`/`.smap` ao lado do módulo agora é localizado pelo caminho completo do
  módulo, e não relativo ao diretório atual.
- **Refactor**: `ConvertMapToSMap`, `MapLocationToStr` e os tipos SMAP foram movidos para `DebugEngine.MapParser`
  (aliases de tipos/constantes foram mantidos em `DebugEngine.DebugInfo`; adicione `DebugEngine.MapParser` ao `uses`
  para chamar as funções).
- `EnumTryBlocks` é somente x64; `TraceTryBlocks` é somente x86 (por desenho dos dois modelos de exceção).
- O Win64x no Delphi 13 usa o mesmo compilador e RTL do Win64, portanto o assembly inline é aceito.
- O MSBuild pode reportar *"command line too long"* (MSB6003) em máquinas com um Library Path global muito longo; é um
  limite do ambiente, não do projeto — compile pelo IDE ou chame `dcc64`/`dcclinux64` diretamente.

---

## Contribuindo

Issues e pull requests são bem-vindos.
