#requires -version 4
set-strictMode -version 4

<#
.SYNOPSIS
    Parses an MKV file

.DESCRIPTION
    Parses an MKV file and optionally prints the structure to console

.OUTPUTS
    System.Collections.Specialized.OrderedDictionary

.PARAMETER filepath
    Input file path

.PARAMETER get
    Level-1 sections to get, an array of strings.
    Default: 'Info','Tracks','Chapters','Attachments' and additionally 'Tags' when printing.
    '*' means everything, *common' - the four above.
    'keyframes' gets a list of keyframes in <result>.keyframes
    'timecodes' gets a list of frame timecodes in <result>.timecodes and same-FPS spans in <result>.timecodeSpans
    'useCFR' along with 'keyframes' assumes the video has constant frame rate and tries to use Cues (mkv seek index) to derive the keyframe list - USE ONLY WHEN 100% SURE THE VIDEO IS CFR

.PARAMETER exhaustiveSearch
    In case a block wasn't found automatically it will be searched
    by sequentially skipping all [usually Cluster] elements which may take a long time

.PARAMETER binarySizeLimit
    Do not autoread binary data bigger than this number of bytes, specify -1 for no limit

.PARAMETER entryCallback
    Code block to be called on each entry.
    Some time/date/tracktype values may yet be raw numbers because processing is guaranteed to occur only after all child elements of a container are read.
    Parameters: entry (with its metadata in _ property).
    Return value: 'abort' to stop all processing, 'skip' to skip current element, otherwise ignored.

.PARAMETER keepStreamOpen
    Leave the BinaryReader stream open in <result>._.reader

.PARAMETER print
    Pretty-print to the console.

.PARAMETER printRaw
    Print the element tree as is.

.PARAMETER printDebug
    printRaw + show file offset, size, element ID

.PARAMETER showProgress
    Show the progress for long operations even when not printing.

.EXAMPLE
    parseMKV 'c:\some\path\file.mkv' -print

.EXAMPLE
    parseMKV 'c:\some\path\file.mkv' -get Info -print

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv'`

    $mkv.Segment.Tracks.Video | %{
        'Video: {0}x{1}, {2}' -f $_.Video.PixelWidth, $_.Video.PixelHeight, $_.CodecID
    }
    $mkv.Segment.Tracks.Audio | %{ $index=0 } {
        'Audio{0}: {1} {2}Hz' -f (++$index), $_.CodecID, $_.Audio.SamplingFrequency
    }
    $audioTracksCount = $mkv.Segment.Tracks.Audio.count

.EXAMPLE
    Extract all attachments

    $mkv = parseMKV 'c:\some\path\file.mkv' -keepStreamOpen -binarySizeLimit 0
    $outputDir = 'd:\'
    echo "Extracting to $outputDir"
    forEach ($att in $mkv.find('AttachedFile')) {
        write-host "`t$($att.FileName)"
        $file = [IO.File]::create((join-path $outputDir $att.FileName))
        $mkv.reader.baseStream.position = $att.FileData._.datapos
        $data = $mkv.reader.readBytes($att.FileData._.size)
        $file.write($data, 0, $data.length)
        $file.close()
    }
    $mkv.reader.close()

.EXAMPLE
    Find/access elements

    $mkv = parseMKV 'c:\some\path\file.mkv'

    $DisplayWidth = $mkv.find('DisplayWidth')
    $DisplayHeight = $mkv.find('DisplayHeight')
    $VideoCodecID = $DisplayWidth._.closest('TrackEntry').CodecID

    $DisplayWxH = $mkv.Segment.Tracks.Video._.find('', '^Display[WH]') -join 'x'

    $mkv.find('ChapterTimeStart')._.displayString -join ", "

    $mkv.find('FlagDefault') | ?{ $_ -eq 1 } | %{ $_._.parent|ft }

    forEach ($chapter in $mkv.find('ChapterAtom')) {
        '{0:h\:mm\:ss}' -f $chapter._.find('ChapterTimeStart') +
        " - " + $chapter._.find('ChapString')
    }
#>

function parseMKV(
    [string]
    [parameter(valueFromPipeline)]
    [validateScript({ if ((test-path -literal $_) -or (test-path $_)) { $true }
                      else { write-warning 'File not found'; throw } })]
    $filepath,

    [string[]]
    [validateSet(
        '*', <# tries to get everything except keyframes/timecodes #>
        '*common', <# is the next 4 #> 'Info','Tracks','Chapters','Attachments',
        'Tags','Tags:whenPrinting',
        'EBML', 'SeekHead','Cluster','Cues',
        'keyframes', 'timecodes', 'useCFR'
    )]
    $get = @('*common', 'Tags:whenPrinting'),

    [int32]
    [validateRange(-1, [int32]::MaxValue)]
    $binarySizeLimit = 16,

    [scriptblock] $entryCallback,

    [switch] $exhaustiveSearch,
    [switch] $keepStreamOpen,

    [switch] $print,
    [switch] $printRaw,
    [switch] $printDebug,
    [switch] $showProgress
) {

process {

    if (!(test-path -literal $filepath)) {
        $filepath = "$(gi $filepath)"
    }
    try {
        $stream = [IO.FileStream]::new(
            $filepath,
            [IO.FileMode]::open,
            [IO.FileAccess]::read,
            [IO.FileShare]::readWrite,
            16, # by default read-ahead is 4096 and we don't need that after every seek
            [IO.FileOptions]::RandomAccess
        )
        $bin = [IO.BinaryReader]$stream
    } catch {
        throw $_
        return $null
    }

    if (!(test-path variable:script:DTD)) {
        init
    }

    $state = @{
        abort = $false # set when entryCallback returns 'abort'
        print = @{ tick=[datetime]::now.ticks }
        timecodeScale = $DTD.Segment.Info.TimecodeScale._.value
    }

    $opt = parseOptions

    $mkv = $dummyMeta.PSObject.copy()
    $mkv.PSObject.members.remove('closest')
    $mkv | add-member ([ordered]@{
        path = '/'
        DTD = $DTD
        ref = $mkv
        _ = $mkv
    })
    $mkv.EBML = [Collections.ArrayList]::new()
    $mkv.Segment = [Collections.ArrayList]::new()

    if ([bool]$keepStreamOpen) {
        $mkv | add-member reader $bin
    }

    while (!$state.abort -and $stream.position -lt $stream.length) {

        $meta = if (findNextRootContainer) { readEntry $mkv }

        if (!$meta -or !$meta['ref'] -or $meta['path'] -notmatch '^/(EBML|Segment)/$') {
            throw 'Cannot find EBML or Segment structure'
        }

        $container = $meta.root = $meta.ref
        $meta.root = $segment = $container
        $allSeekHeadsFound = $false

        if ($entryCallback -and (& $entryCallback $container) -eq 'abort') {
            $state.abort = $true
            break
        }
        if ($opt.print -and !$opt.printRaw) {
            printEntry $container
        }

        readChildren $container
    }

    if ($opt.get['KFTC'] -and !$state.abort `
    -and !$mkv['keyframes'] -and !$mkv['timecodes'] `
    -and $mkv.Segment -and $mkv.Segment[0]['Cluster']) {
        indexMKV
    }

    if (![bool]$keepStreamOpen) {
        $bin.close()
    }
    if ($opt.print) {
        if ($state.print['needLineFeed']) {
            $host.UI.writeLine()
        }
        if ($state.print['progress']) {
            write-progress $state.print.progress -completed
        }
    }

    makeSingleParentsTransparent $mkv
    $mkv
}

}

#region MAIN

function parseOptions {
    $opt = @{
        get = @{ EBML='auto'; Segment='auto'; SeekHead='auto' }
        exhaustiveSearch = [bool]$exhaustiveSearch
        binarySizeLimit = $binarySizeLimit
        print = [bool]$print -or [bool]$printRaw
        printRaw = [bool]$printRaw -or [bool]$printDebug
        printDebug = [bool]$printDebug
        showProgress = [bool]$showProgress -or [bool]$print -or [bool]$printRaw
    }
    if ('*' -in $get) {
        $DTD, $DTD.Segment | %{
            $_.getEnumerator() | ?{ $_.name -ne '_' } | %{ $opt.get[$_.name] = 'auto' }
        }
    }
    if ('*common' -in $get) {
        'Info', 'Tracks', 'Chapters', 'Attachments' | %{ $opt.get[$_] = 'auto' }
    }
    if ('keyframes' -in $get -or 'timecodes' -in $get) {
        $opt.get.Info = $opt.get.Tracks = $true
        $opt.get.KFTC = $opt.get.Cluster = 'find'
        if ('useCFR' -in $get) { $opt.get.Cues = 'find' }
    }
    if ($opt.print -and 'Tags:whenPrinting' -in $get) {
        $opt.get.Tags = $true
    }
    $get | ?{ $_ -match '^\w+$' } | %{ $opt.get[$_] = $true }
    $opt
}

function findNextRootContainer {
    $toRead = 4 # EBML/Segment ID size
    $buf = [byte[]]::new($lookupChunkSize)
    forEach ($step in 1..128) {
        $bufsize = $bin.read($buf, 0, $toRead)
        $bufstr = [BitConverter]::toString($buf, 0, $bufsize)
        forEach ($id in <#EBML#>'1A-45-DF-A3', <#Segment#>'18-53-80-67') {
            $pos = $bufstr.indexOf($id)/3
            if ($pos -ge 0) {
                $stream.position -= $bufsize - $pos
                return $true
            }
        }
        $toRead = $buf.length
        $stream.position -= 4
    }
}

function readChildren($container) {

    function gotLevel1 {
        $name = $meta.name
        $info = $DTD.Segment[$name]
        if ($info -and (!$info._['multiple'] -or $opt.get[$name] -eq 'find')) {
            $opt.get.remove($name)
        }
    }

    $opt = $opt
    $stream = $stream
    $stream.position = $container._.datapos
    $stopAt = if ($container._.size) { $container._.datapos + $container._.size } else { $stream.length }
    $lastContainerServed = $false

    while ($stream.position -lt $stopAt -and !$state.abort) {

        $meta = readEntry $container $stopAt
        if (!$meta) {
            break
        }

        $child = $meta.ref

        if (!$meta['skipped']) {
            if ($meta.type -ne 'container' -or $meta.size -eq 0) {
                continue
            }
            if (!$opt.print -or $state.print['postponed']) {
                readChildren $child
            } elseif ($meta.path -cnotmatch $printPostponed -or $opt.printRaw) {
                if (!$opt.printRaw) {
                    printEntry $child
                }
                readChildren $child
            } elseif ($matches) {
                $state.print.postponed = $true
                readChildren $child
                printEntry $child
                printChildren $child -includeContainers
                $state.print.postponed = $false
            }
            if ($meta.level -eq 1) { gotLevel1 }
            continue
        }
        if ($meta.level -eq 1) { gotLevel1 }
        if ($lastContainerServed -or $meta.name -eq 'Void') {
            continue
        }
        if ($segment['SeekHead']) {
            if (!($requestedSections = $opt.get.getEnumerator().where({ [string]$_.value -ne 'auto' }))) {
                $stream.position = $stopAt
                break
            }
            if ($meta.name -ne 'Cluster' -and $requestedSections.name -eq 'Cluster') {
                continue
            }
            $pos = $segment._.datapos + $segment._.size
            forEach ($section in $requestedSections.name) {
                $p = $segment.SeekHead.named[$section]
                if (!$p -and !$allSeekHeadsFound) {
                    $allSeekHeadsFound = $true
                    if ($segment.SeekHead.named['SeekHead']) {
                        processSeekHead -findAll
                        $p = $segment.SeekHead.named[$section]
                    }
                }
                if ($p -lt $pos -and $p -gt $meta.datapos) {
                    $pos = $p
                }
            }
            $stream.position = $pos
            continue
        }
        if ($meta.name -eq 'Cluster' -and $opt.get['Cluster'] -ne $true) {
            # here we don't need clusters and we don't have SeekHead
            # so in case more explicitly requested sections are needed
            # we'll try locating them at the end of the file
            if (($opt['exhaustiveSearch'] -or ($opt.get.values -eq $true)) -and (locateLastContainer)) {
                $lastContainerServed = $true
                continue
            }
            if (!$opt['exhaustiveSearch']) {
                $stream.position = $stopAt
                break
            }
        }
        if ($opt.showProgress -and ([datetime]::now.ticks - $state.print['progresstick'] -ge 1000000)) {
            showProgressIfStuck
        }
    }

    if ($container._.name -eq 'SeekHead') {
        processSeekHead $container
    }

    makeSingleParentsTransparent $container

    if ($opt.print -and !$opt.printRaw -and !$state.abort -and !$state.print['postponed']) {
        printChildren $container
    } elseif ($opt.showProgress -and ([datetime]::now.ticks - $state.print['progresstick'] -ge 1000000)) {
        showProgressIfStuck
    }
}

function makeSingleParentsTransparent($container) {
    # make single container's properties directly enumerable
    # thus allowing to type $mkv.Segment.Info.SegmentUID without [0]'s
    forEach ($child in $container.getEnumerator()) {
        if ($child.value -is [Collections.ArrayList] `
        -and $child.value.count -eq 1 `
        -and $child.value[0]._.type -ceq 'container' `
        -and $child.value[0].count -gt 0) {
            add-member ([ordered]@{} + $child.value[0]) -inputObject $child.value
        }
    }
}

function readEntry($container, $stopAt) {

    function bakeTime($value=$value, $meta=$meta, [bool]$ms, [bool]$fps, [switch]$noScaling) {
        [uint64]$nanoseconds = if ([bool]$noScaling) { $value }
                               else { $value * $state.timecodeScale }
        $time = [TimeSpan]::new($nanoseconds / 100)
        if ($ms) {
            $fpsstr = if ($fps -and $container['TrackType'] -match '^(1|Video)$') {
                ', ' + (1000000000 / $value).toString('g5',$numberFormat) + ' fps'
            }
            $meta.displayString = ('{0:0}ms' -f $time.totalMilliseconds) + $fpsstr
        } else {
            $meta.displayString = '{0}{1}s ({2:hh\:mm\:ss\.fff})' -f `
                $time.totalSeconds.toString('n0',$numberFormat),
                (('.{0:000}' -f $time.milliseconds) -replace '\.000',''),
                $time
        }
        $meta.rawValue = $value
        $time
    }

    # inlining because PowerShell's overhead for a simple function call
    # is bigger than the time to execute it

    $bin = $bin
    $stream = $stream
    $opt = $opt
    $VINT = [byte[]]::new(8)
    $globalIDs = $DTD._.globalIDs
    $pathIDs = $DTD._.pathIDs

    $parentMeta = $container._

    do {
        $meta = $dummyMeta.PSObject.copy()
        $meta.pos = $stream.position

        $VINT.clear()
        $VINT[0] = $first = $bin.readByte()
        $id = $meta.id =
            if ($first -eq 0 -or $first -eq 0xFF) {
                -1
            } elseif ($first -ge 0x80) {
                $first
            } elseif ($first -ge 0x40) {
                [int]$first -shl 8 -bor $bin.readByte()
            } else {
                $len = 8 - [byte][Math]::floor([Math]::log($first)/[Math]::log(2))
                $bin.read($VINT, 1, $len - 1) >$null
                [Array]::reverse($VINT, 0, $len)
                [BitConverter]::toUInt64($VINT, 0)
            }

        if (!($info = $globalIDs[$id])) {
            if (!($info = $pathIDs[$parentMeta.path][$id])) {
                $info = $DTD
                forEach ($subpath in ($parentMeta.path.substring(1) -split '/')) {
                    if ($subpath -and (!$info._['recursiveNesting'] -or $subpath -ne $info._.name)) {
                        $info = $info[$subpath]
                    }
                }
                $info = $info._.IDs[$id]
            }
        }
        if ($info) {
            $info = $info._
            $name = $meta.name = $info.name
            $type = $meta.type = $info.type
        } else {
            $info = @{}
            $name = $meta.name = '?'
            $type = $meta.type = 'binary'
            $meta.displayString = 'ID {0:x2}' -f $id
        }

        $path = $meta.path = $parentMeta.path + $name + '/'*[int]($type -eq 'container')

        $size = $meta.size =
            if ($info -and $info.contains('size')) {
                $info.size
            } else {
                $VINT.clear()
                $VINT[0] = $first = $bin.readByte()
                if ($first -eq 0xFF) {
                    $null # unknown size, usually streamed content or dynamically written
                } elseif ($first -ge 0x80) {
                    $first -band 0x7F
                } elseif ($first -ge 0x40) {
                    ([int]$first -band 0x3F) -shl 8 -bor $bin.readByte()
                } else {
                    $len = 8 - [byte][Math]::floor([Math]::log($first)/[Math]::log(2))
                    $VINT[0] = $first -band -bnot (1 -shl (8-$len))
                    $bin.read($VINT, 1, $len - 1) >$null
                    [Array]::reverse($VINT, 0, $len)
                    [BitConverter]::toUInt64($VINT, 0)
                }
            }

        $datapos = $meta.datapos = $stream.position

        if (!$info) {
            $stream.position += $size
            return $meta
        }

        $meta.level = if ($parentMeta.contains('level')) { $parentMeta.level + 1 } else { 0 }
        $meta.root = $parentMeta['root']
        $meta.parent = $container

        if ((($type -eq 'container' -and $meta.level -eq 1) -or $name -eq 'Void') -and !$opt.get[$name]) {
            $stream.position += $size
            $meta.ref = [ordered]@{ _=$meta }
            $meta.skipped = $true
            $state.abort = $entryCallback -and (& $entryCallback $meta.ref) -eq 'abort'
            return $meta
        }

        if ($opt.get['KFTC'] -and 'Cluster','Cues' -eq $name -and $opt.get[$name] -ne $true) {
            $meta.skipped = $true
        }

        if ($type -eq 'container') {
            $meta.ref = $result = $dummyContainer.PSObject.copy()
            $result._ = $meta
        } else {
            if ($size) {
                if ($type -eq 'int') {
                    if ($size -eq 1) {
                        $value = $bin.readSByte()
                    } else {
                        $VINT.clear()
                        $bin.read($VINT, 0, $size) >$null
                        [Array]::reverse($VINT, 0, $size)
                        $value = [BitConverter]::toInt64($VINT, 0)
                        if ($size -lt 8 -and $VINT[$size-1] -ge 0x80) {
                            $value -= ([int64]1 -shl $size*8)
                        }
                    }
                }
                elseif ($type -eq 'uint') {
                    if ($size -eq 1)     { $value = $bin.readByte() }
                    elseif ($size -eq 2) { $value = [int]$bin.readByte() -shl 8 -bor $bin.readByte() }
                    else {
                        $VINT.clear()
                        $bin.read($VINT, 0, $size) >$null
                        [Array]::reverse($VINT, 0, $size)
                        $value = [BitConverter]::toUInt64($VINT, 0)
                    }
                }
                elseif ($type -eq 'float') {
                    $buf = $bin.readBytes($size)
                    [Array]::reverse($buf)
                    $value = if ($size -eq 4)  { [BitConverter]::toSingle($buf, 0) }
                         elseif ($size -eq 8)  { [BitConverter]::toDouble($buf, 0) }
                         elseif ($size -eq 10) { decodeLongDouble $buf }
                         else { write-warning "FLOAT should be 4, 8 or 10 bytes, got $size"
                            0.0
                         }
                }
                elseif ($type -eq 'date') {
                    $rawvalue = if ($size -ne 8) {
                        write-warning "DATE should be 8 bytes, got $size"
                        0
                    } else {
                        $bin.read($VINT, 0, 8) >$null
                        [Array]::reverse($VINT)
                        [BitConverter]::toInt64($VINT,0)
                    }
                    $value = ([datetime]'2001-01-01T00:00:00.000Z').addTicks($rawvalue/100)
                }
                elseif ($type -eq 'string') {
                    $value = [Text.Encoding]::UTF8.getString($bin.readBytes($size))
                }
                elseif ($type -eq 'binary') {
                    $readSize = if ($opt.binarySizeLimit -lt 0 -or $name -eq 'SeekID') { $size }
                                else { [Math]::min($opt.binarySizeLimit, $size) }
                    if ($readSize) {
                        $value = $bin.readBytes($readSize)

                        if ($name.endsWith('UID')) {
                            $meta.displayString = bin2hex $value
                        }
                        elseif ($name -eq '?') {
                            $s = [Text.Encoding]::UTF8.getString($value)
                            if ($s -cmatch '^[\x20-\x7F]+$') {
                                $meta.displayString += ' data: ' +
                                    [BitConverter]::toString($value, 0,
                                                                [Math]::min(16,$value.length)) +
                                    @('','...')[[int]($readSize -gt 16)] +
                                    " possible ASCII string: $s"
                            }
                        }
                    } else {
                        $value = [byte[]]::new(0)
                    }
                }
            }
            elseif ($info.contains('value')) {
                $value = $info.value
            }
            elseif ($type -eq 'int')    { $value = 0 }
            elseif ($type -eq 'uint')   { $value = 0 }
            elseif ($type -eq 'float')  { $value = 0.0 }
            elseif ($type -eq 'string') { $value = '' }
            elseif ($type -eq 'binary') { $value = [byte[]]::new(0) }

            $typecast =
                if ($type -eq 'int')       { if ($size -le 4) { [int32] }  else { [int64] } }
                elseif ($type -eq 'uint')  { if ($size -le 4) { [uint32] } else { [uint64] } }
                elseif ($type -eq 'float') { if ($size -eq 4) { [single] } else { [double] } }

            # using explicit assignment to keep empty values that get lost in $var=if....
            if ($typecast) {
                $result = $value -as $typecast
            } else {
                $result = $value
            }

            # cook the values
            if ($path.endsWith('/Info/TimecodeScale')) {
                $state.timecodeScale = $value
                if ($dur = $container['Duration']) {
                    setEntryValue $dur (bakeTime $dur $dur._)
                }
            }
            elseif ($path.endsWith('/Info/Duration') `
                -or $path.endsWith('/Cluster/Timecode') `
                -or $path.endsWith('/CuePoint/CueTime')) {
                $result = bakeTime
            }
            elseif ($path.endsWith('/CueTrackPositions/CueDuration') `
                -or $path.endsWith('/BlockGroup/BlockDuration')) {
                $result = bakeTime -ms:$true
            }
            elseif ($path.endsWith('/ChapterAtom/ChapterTimeStart') `
                -or $path.endsWith('/ChapterAtom/ChapterTimeEnd')) {
                $result = [TimeSpan]::new($value / 100)
                $meta.displayString = '{0:hh\:mm\:ss\.fff}' -f $result
            }
            elseif ($path.endsWith('/TrackEntry/DefaultDuration') `
                -or $path.endsWith('/TrackEntry/DefaultDecodedFieldDuration')) {
                $result = bakeTime -ms:$true -fps:$true -noScaling
            }
            elseif ($path.endsWith('/TrackEntry/TrackType')) {
                if ($value = $DTD._.trackTypes[[int]$result]) {
                    $meta.rawValue = $result
                    $result = $value
                    $tracks = $container._.parent
                    if ($existing = $tracks[$value]) {
                        $existing.add($container) >$null
                    } else {
                        $tracks[$value] = [Collections.ArrayList]@($container)
                    }
                }
                'DefaultDuration', 'DefaultDecodedFieldDuration' | %{
                    if ($dur = $container[$_]) {
                        setEntryValue $dur (bakeTime $dur $dur._ -ms:$true -fps:$true -noScaling)
                    }
                }
            }
            # this single line consumes up to 50% of the entire processing time
            $meta.ref = add-member _ $meta -inputObject $result -passthru
        }
        $stream.position = $datapos + $size

        $existing = $container[$name]
        if ($existing -eq $null) {
            if ($info['multiple']) {
                $container[$name] = [Collections.ArrayList]@($meta.ref)
            } else {
                $container[$name] = $meta.ref
            }
        } elseif ($existing -is [Collections.ArrayList]) {
            $existing.add($meta.ref) >$null
        } else { # should never happen according to DTD but just in case
            $container[$name] = [Collections.ArrayList]@($existing, $meta.ref)
        }

        if ($entryCallback) {
            $cbStatus = & $entryCallback $meta.ref
            if ($cbStatus -eq 'abort') { $state.abort = $true; break }
            if ($cbStatus -eq 'skip')  { $meta.skipped = $true; break }
        }

        if ($opt.printRaw -and !$meta['skipped'] -and !$meta['abort']) {
            printEntry $meta.ref
        }
    } until (!$stopAt -or $stream.position -ge $stopAt -or ($type -eq 'container' -and $size -ne 0))

    $meta
}

function locateLastContainer {
    [uint64]$end = $segment._.datapos + $segment._.size

    $maxBackSteps = [int]0x100000 / $lookupChunkSize # max 1MB

    if ($stream.position + 16*$meta.size + $maxBackSteps*$lookupChunkSize -gt $end) {
        # do nothing if the stream's end is near
        return
    }

    $vint = [byte[]]::new(8)
    $IDs = 'Tags','SeekHead','Cluster','Cues','Chapters','Attachments','Tracks','Info' | %{
        $IDhex = $DTD.Segment[$_]._.id.toString('X')
        if ($IDhex.length -band 1) { $IDhex = '0' + $IDhex }
        ($IDhex -replace '..', '-$0').substring(1)
    }
    $last = $end

    forEach ($step in 1..$maxBackSteps) {
        $stream.position = $start = $end - $lookupChunkSize*$step
        $buf = $bin.readBytes($lookupChunkSize + 8*2) # max 8-byte id and size
        $haystack = [BitConverter]::toString($buf)

        # try locating Tags first but in case the last section is
        # Clusters or Cues assume there's no Tags anywhere and just report success
        # in order for readChildren to finish its job peacefully
        forEach ($IDhex in $IDs) {
            $idlen = ($IDhex.length+1)/3
            $idpos = $buf.length
            while ($idpos -gt 0) {
                $idpos = $haystack.lastIndexOf($IDhex, ($idpos-1)*3) / 3
                if ($idpos -lt 0) {
                    break
                }
                # try reading 'size'
                $sizepos = $idpos + $idlen
                $first = $buf[$sizepos]
                if ($first -eq 0 -or $first -eq 0xFF) {
                    continue
                }
                $sizelen = 8 - [byte][Math]::floor([Math]::log($first)/[Math]::log(2))
                if ($sizepos + $sizelen -ge $buf.length) {
                    continue
                }
                $first = $first -band -bnot (1 -shl (8-$sizelen))
                $size = if ($sizelen -eq 1) {
                        $first
                    } else {
                        $vint.clear()
                        $vint[0] = $first
                        [Buffer]::blockCopy($buf, $sizepos+1, $vint, 1, $sizelen-1)
                        [Array]::reverse($vint, 0, $sizelen)
                        [BitConverter]::toUInt64($vint, 0)
                    }
                if ($start + $sizepos + $sizelen + $size -ne $last) {
                    continue
                }
                $section = $DTD.Segment._.IDs[$IDhex -replace '-','']
                if ($section -and $opt.get[$section._.name]) {
                    $stream.position = $start + $idpos
                    return $true
                }
                if ($last -eq $end) {
                    $last = $start + $idpos
                }
            }
        }
    }
    $stream.position = if ($last -ne $end) { $last } else { $meta.datapos + $meta.size }
    return $last -ne $end
}

function processSeekHead($SeekHead = $segment.SeekHead, [switch]$findAll) {
    $SeekHead, $segment.SeekHead | %{
        if (!$_.PSObject.properties['named']) {
            add-member named @{} -inputObject $_
        }
    }

    $savedPos = $stream.position
    $moreHeads = [Collections.ArrayList]::new()

    forEach ($seek in $SeekHead.Seek) {
        if ($section = $DTD.Segment._.IDs["0x$(bin2hex $seek.SeekID)"]) {
            $pos = $segment._.datapos + $seek.SeekPosition
            if ($section._.name -eq 'SeekHead') {
                # skip SeekHead if it's already been read
                if ($segment.SeekHead._.pos -notcontains $pos) {
                    $moreHeads.add($pos) >$null
                }
            } else {
                $SeekHead.named, $segment.SeekHead.named | %{ $_[$section._.name] = $pos }
            }
        }
    }

    if ([bool]$findAll) {
        forEach ($pos in $moreHeads) {
            $stream.position = $pos
            if ($meta = readEntry $segment) {
                readChildren $meta.ref
            }
        }
        $stream.position = $savedPos
    }
}

#endregion
#region UTILITIES

function setEntryValue($entry, $value) {
    $meta = $entry._
    $raw = $entry.PSObject.copy(); $raw.PSObject.members.remove('_')
    $meta.rawValue = $raw
    $entry = add-member _ $meta -inputObject $value -passthru
    $entry._.parent[$meta.name] = $entry
    $entry
}

function bin2hex([byte[]]$value) {
    if ($value) { [BitConverter]::toString($value) -replace '-', '' }
    else { '' }
}

function decodeLongDouble([byte[]]$data) {
    # Converted from C# function
    # Original author: Nathan Baulch (nbaulch@bigpond.net.au)
    #   http://www.codeproject.com/Articles/6612/Interpreting-Intel-bit-Long-Double-Byte-Arrays
    # References:
    #   http://cch.loria.fr/documentation/IEEE754/numerical_comp_guide/ncg_math.doc.html
    #   http://groups.google.com/groups?selm=MPG.19a6985d4683f5d398a313%40news.microsoft.com

    if (!$data -or $data.count -lt 10) {
        return $null
    }

    [int16]$e = ($data[9] -band 0x7F) -shl 8 -bor $data[8]
    if (!$e) { return 0.0 } # subnormal, pseudo-denormal or zero

    [byte]$j = $data[7] -band 0x80
    if (!$j) { return $null }

    [int64]$f = $data[7] -band 0x7F
    forEach ($i in 6..0) {
        $f = $f -shl 8 -bor $data[$i]
    }

    [byte]$s = $data[9] -band 0x80

    if ($e -eq 0x7FFF) {
        if ($f) { return [double]::NaN }
        if (!$s) { return [double]::positiveInfinity }
        return [double]::negativeInfinity
    }

    $e -= 0x3FFF - 0x3FF
    if ($e -ge 0x7FF) { return $null } # outside the range of a double
    if ($e -lt -51) { return 0.0 } # too small to translate into subnormal

    $f = $f -shr 11

    if ($e -lt 0) { # too small for normal but big enough to represent as subnormal
        $f = ($f -bor 0x10000000000000) -shr (1 - $e)
        $e = 0
    }

    [byte[]]$new = [BitConverter]::getBytes($f)
    $new[7] = $s -bor ($e -shr 4)
    $new[6] = (($e -band 0x0F) -shl 4) -bor $new[6]

    [BitConverter]::toDouble($new, 0)
}

#endregion
#region PRINT

function printChildren($container, [switch]$includeContainers) {
    $printed = @{}
    $list = {0}.invoke()
    forEach ($child in $container.values) {
        if ($child._.type -eq 'container' -and ![bool]$includeContainers) {
            continue
        }
        if ($child -is [Collections.ArrayList]) {
            $toPrint = $child
        } else {
            $list[0] = $child
            $toPrint = $list
        }
        forEach ($entry in $toPrint) {
            $hash = [Runtime.CompilerServices.RuntimeHelpers]::getHashCode($entry)
            if (!$printed[$hash] -and !$entry._['skipped']) {
                printEntry $entry
                $printed[$hash] = $true
            }
        }
    }
}

function printEntry($entry) {

    function xy2ratio([int]$x, [int]$y) {
        [int]$a = $x; [int]$b = $y
        while ($b -gt 0) {
            [int]$rem = $a % $b
            $a = $b
            $b = $rem
        }
        "$($x/$a):$($y/$a)"
    }

    function prettySize([uint64]$size) {
        [uint64]$base = 0x10000000000
        $s = $alt = ''
        @('TiB','GiB','MiB','KiB').where({
            if ($size / $base -lt 1) {
                $base = $base -shr 10
            } else {
                $alt = ($size / $base).toString('g3', $numberFormat) + ' ' + $_
                $true
            }
        }, 'first') >$null
        $s = $size.toString('n0', $numberFormat) + ' bytes'
        if ($alt) { $alt, " ($s)" } else { $s, '' }
    }

    function printSimpleTags($entry) {
        $statsDelim = '  '*($entry._.level+1)
        forEach ($stag in $entry.SimpleTag) {
            if ($stag.TagName.startsWith('_STATISTICS_')) {
                continue
            }
            $stats = switch ($stag.TagName) {
                'BPS' {
                    ($stag.TagString / 1000).toString('n0', $numberFormat); $alt = ' kbps' }
                'DURATION' {
                    $stag.TagString -replace '.{6}$',''; $alt = '' }
                'NUMBER_OF_FRAMES' {
                    ([uint64]$stag.TagString).toString('n0', $numberFormat); $alt = ' frames' }
                'NUMBER_OF_BYTES' {
                    $s, $alt = prettySize $stag.TagString
                    $s
                }
            }
            if ($stats) {
                $host.UI.write($colors.dim, 0, $statsDelim)
                $host.UI.write($colors[@('value','normal')[[int]!$alt]], 0, $stats)
                $host.UI.write($colors.dim, 0, $alt)
                $statsDelim = ', '
                continue
            }
            $default = if ($stag['TagDefault'] -eq 1) { '*' } else { '' }
            $flags = $default + $stag['TagLanguage']
            $host.UI.write($colors.normal, 0,
                ('  '*$stag._.level) + $stag.TagName + ($flags -replace '^\*eng$',': '))
            $host.UI.write($colors.dim, 0, ("/$flags" -replace '/(\*eng)?$','') + ': ')
            if ($stag.contains('TagString')) {
                $host.UI.write($colors.stringdim2, 0, $stag.TagString)
            } elseif ($stag.contains('TagBinary')) {
                $tb = $stag.TagBinary
                if ($tb.length) {
                    $ellipsis = if ($tb.length -lt $tb._.size) { '...' } else { '' }
                    $host.UI.write($colors.dim, 0, "[$($tb._.size) bytes] ")
                    $host.UI.write($colors.stringdim2, 0,
                        ((bin2hex $tb) -replace '(.{8})', '$1 ') + $ellipsis)
                }
            }
            $host.UI.writeLine()

            if ($stag['SimpleTag']) {
                printSimpleTags $stag
            }
        }
    }

    function listTracksFor([string[]]$IDs, [string]$IDname) {
        $tracks = $segment['Tracks']
        if (!$tracks) {
            return
        }
        $comma = ''
        forEach ($ID in $IDs) {
            if ($track = $tracks.TrackEntry.where({ $_[$IDname] -eq $ID }, 'first')) {
                $track = $track[0]
                $host.UI.write($colors.normal, 0,
                    $comma + '#' + $track.TrackNumber + ': ' + $track.TrackType)
                if ($track['Name']) {
                    $host.UI.write($colors.reference, 0, " ($($track.Name))")
                }
                $comma = ', '
            }
        }
    }

    $meta = $entry._
    if ($meta['skipped']) {
        return
    }

    $last = $state.print
    if ($last['progress']) {
        write-progress $last.progress -completed
        $last.progress = $null
    }
    $emptyBinary = $meta.type -eq 'binary' -and !$entry.length
    if ($emptyBinary -and $last['emptyBinary'] -and $last['path'] -eq $meta.path) {
        $last['skipped']++
        $last['skippedSize'] += $meta.size
        return
    }
    if ($last['path']) {
        if ($last['skipped']) {
            $host.UI.writeLine($colors.dim, 0,
                " [$($last.skipped) entries skipped, $((prettySize $last.skippedSize) -join '')]")
            $last.skipped = $last.skippedSize = 0
        } elseif ($last['needLineFeed']) {
            $host.UI.writeLine()
        } else {
            $last['needLineFeed'] = $true
        }
    }
    $last.path = $meta.path
    $last.tick = [datetime]::now.ticks
    $last.emptyBinary = $emptyBinary

    $indent = '  '*$meta.level
    if ($opt.printDebug) {
        $color = if ($meta.type -eq 'container') {
            if ($meta.level -le 1) { $colors.bold } else { $colors.normal }
        } else {
            $colors.dim
        }
        $host.UI.write($color, 0,
            ("{0,10:d} {1,9:d} {2,8}`t" -f $meta.pos, $meta.size, ('{0:x8}' -f $meta.id -replace '^(00)+','')))
    }

    if (!$opt.printRaw) {
      $last['needLineFeed'] = $false
      switch -regex ($meta.path) {
        '^/Segment/$' {
            if (($i = $meta.parent.Segment.count) -gt 1) {
                $host.UI.write($colors.container, 0, "`n${indent}Segment #$i")
            }
        }
        '/TrackEntry/$' {
            $type = $entry.TrackType
            $flags = if ($entry['FlagForced'] -eq 1) { '!' } else { '' }
            $flags += if ($entry['FlagDefault'] -eq 1) { '*' }
            $flags += if ($entry['FlagEnabled'] -eq 0) { '-' }

            $host.UI.write($colors.container, 0, "$indent$type $($flags -replace '.$','$0 ')")
            $host.UI.write($colors.normal, 0, $entry.CodecID + ' ')

            $s = $alt = ''
            switch ($type) {
                'Video' {
                    $w = $entry.Video.PixelWidth
                    $h = $entry.Video.PixelHeight
                    $i = if ($entry.Video['FlagInterlaced'] -eq 1) { 'i' } else { '' }
                    $host.UI.write($colors.value, 0, "${w}x$h$i ")

                    $dw = $entry.Video['DisplayWidth']; if (!$dw) { $dw = $w }
                    $dh = $entry.Video['DisplayHeight']; if (!$dh) { $dh = $h }
                    $DAR = xy2ratio $dw $dh
                    $SAR = xy2ratio $w $h
                    if ($SAR -eq $DAR) {
                        $SAR = ''
                    } else {
                        $DARden = ($DAR -split ':')[-1]
                        $DAR = "DAR $DAR"
                        $PAR = xy2ratio ($dw*$h) ($w*$dh)
                        $SAR = ', orig ' + ($w / $h).toString('g4',$numberFormat) + ", PAR $PAR"
                    }
                    $host.UI.write($colors.dim, 0, "($DAR or $(($dw/$dh).toString('g4',$numberFormat))$SAR) ")

                    $d = $entry['DefaultDuration']
                    if (!$d) { $d = $entry['DefaultDecodedFieldDuration'] }
                    $fps = if ($d) { ($d._.displayString -replace '^.+?, ', '') + ' ' } else { '' }
                    $host.UI.write($colors.value, 0, $fps)
                }
                'Audio' {
                    $s += if ($ch = $meta.find('Channels')) { "${ch}ch " }
                    $hz = $meta.find('SamplingFrequency')
                    if (!($hzOut = $meta.find('OutputSamplingFrequency'))) { $hzOut = $hz }
                    $s += if ($hzOut) { ($hzOut/1000).toString($numberFormat) + 'kHz ' }
                    $s += if ($hzOut -and $hzOut -ne $hz) { '(SBR) ' }
                    $s += if ($bits = $meta.find('BitDepth')) { "${bits}bit " }
                    $host.UI.write($colors.value, 0, $s)
                }
            }
            $lng = "$($entry['Language'])" -replace 'und',''
            if (!$lng) { $lng = $DTD.Segment.Tracks.TrackEntry.Language._.value }
            $name = $entry['Name']
            if ($lng) {
                $host.UI.write($colors.bold, 0, $lng)
                if ($name) { $host.UI.write($colors.dim, 0, '/') }
            }
            if ($name) {
                $host.UI.write($colors.string, 0, $name + ' ')
            }
            $host.UI.writeLine()
            return
        }
        '/ChapterAtom/$' {
            $enabled = if ($entry['ChapterFlagEnabled'] -ne 0) { 1 } else { 0 }
            $hidden = if ($entry['ChapterFlagHidden'] -eq 1) { 1 } else { 0 }
            $flags = if ($enabled) { '' } else { '?' }
            $flags += if ($hidden) { '-' }
            $color = (1-$enabled) + 2*$hidden
            $host.UI.write($colors[@('container','normal','dim')[$color]], 0,
                "${indent}Chapter ")
            $host.UI.write($colors[@('normal','normal','dim')[$color]], 0,
                $entry.ChapterTimeStart._.displayString + ' ')
            $host.UI.write($colors.dim, 0,
                ($flags -replace '.$', '$0 '))
            forEach ($display in [array]$entry['ChapterDisplay']) {
                if ($display -ne $entry.ChapterDisplay[0]) {
                    $host.UI.write($colors.dim, 0, ' ')
                }
                $lng = $display['ChapLanguage']
                if (!$lng) {
                    $lng = $DTD.Segment.Chapters.EditionEntry.ChapterAtom.ChapterDisplay.ChapLanguage._.value
                }
                if ($lng -and $lng -ne 'und') {
                    $host.UI.write($colors.dim, 0, $lng.trim() + '/')
                }
                if ($display['ChapString']) {
                    $host.UI.write($colors[@('string','normal','dim')[$color]], 0, $display.ChapString)
                }
            }
            $host.UI.writeLine()
            if ($UID = $entry['ChapterSegmentUID']) {
                if ($end = $entry['ChapterTimeEnd']) {
                    $s = "${indent}        $($end._.displayString) "
                } else {
                    $s = "${indent}    "
                }
                $host.UI.write($colors.normal, 0, $s)
                $host.UI.writeLine($colors.dim, 0, "UID: $(bin2hex $UID)")
            }
            return
        }
        '/EditionEntry/$' {
            $flags = 'Ordered','Default','Hidden' | %{
                @('',$_.toLower())[[int]($entry["EditionFlag$_"] -eq 1)]
            }
            $host.UI.write($colors.container, 0, "${indent}Edition ")
            if (($flags -join '')) {
                $host.UI.write($colors.value, 0, $flags)
            }
            $host.UI.writeLine()
            return
        }
        '/AttachedFile/FileName$' {
            $att = $meta.parent
            $host.UI.write($colors.container, 0, ('  '*$att._.level) + 'AttachedFile ')
            $host.UI.write($colors.string, 0, $entry + ' ')
            $s, $alt = prettySize $att.FileData._.size
            $host.UI.write($colors[@('value','dim')[[int]!$alt]], 0, $s)
            $host.UI.write($colors.dim, 0, $alt)
            $host.UI.writeLine($colors.stringdim, 0, $att['FileDescription'])
            return
        }
        '/Tag/$' {
            $host.UI.write($colors.container, 0, "${indent}Tags ")
            listTracksFor $entry.Targets['TagTrackUID'] 'TrackUID'
            $host.UI.writeLine()
            printSimpleTags $entry
            $host.UI.writeLine("`n")
            return
        }
        '/CuePoint/$' {
            $cueTime = $entry.CueTime._.displayString -split ' '
            foreach ($cue in $entry.CueTrackPositions) {
                $host.UI.write($colors.container, 0, "${indent}Cue: ")
                $host.UI.write($colors.normal, 0, 'track ')
                $host.UI.write($colors.reference, 0, "$($cue.CueTrack) ")
                $host.UI.write($colors.dim, 0, $cueTime[0] + ' ')
                $host.UI.write($colors.value, 0, $cueTime[1] + ' ')
                $host.UI.write($colors.normal, 0, '-> ' + $cue.CueClusterPosition +
                    ($cue['CueRelativePosition'] -replace '^.',':$0') + "`t")
                listTracksFor @($cue.CueTrack) 'TrackNumber'
                $host.UI.writeLine()
            }
            if ($entry.CueTrackPositions.count -gt 1) {
                $host.UI.writeLine()
            }
            return
        }
        '/Info/(DateUTC|(Muxing|Writing)App)$' {
            if ($meta.parent['MuxingApp'] -eq 'no_variable_data') {
                return
            }
        }
        $printPretty {
            return
        }
        '^/Segment/\w+/$' {
            $host.UI.writeLine()
        }
      }
    }

    $color = if ($meta.type -eq 'container') { 'container' } else { 'normal' }
    $host.UI.write($colors[$color], 0, "$indent$($meta.name) ")

    $s = if ($meta.contains('displayString')) {
        $meta.displayString
    } elseif ($meta.type -eq 'binary') {
        if ($entry.length) {
            $s = ((bin2hex $entry) -replace '(.{8})', '$1 ')
            if (!$opt.printDebug) { $s = "[$($meta.size) bytes] $s" }
            if ($entry.length -lt $meta.size) { "$s..." } else { $s }
        }
    } elseif ($meta.type -ne 'container') {
        "$entry"
    }
    $color = if ($meta.name.endsWith('UID')) { 'dim' }
             else { switch ($meta.type) { string { 'string' } binary { 'dim' } default { 'value' } } }
    $host.UI.write($colors[$color], 0, $s)
    $last.needLineFeed = $true
}

function showProgressIfStuck {
    $tick = [datetime]::now.ticks
    $print = $state.print
    <# after 0.5sec of silence #>
    if ($tick - $print.tick -lt 5000000) {
        return
    }
    $print.progresstick = $tick
    if ($meta.path -match '/Cluster/') {
        $section = $segment
    } else {
        $section = $meta.closest('','/Segment/\w+/$')
    }
    $size = $section._.size; if (!$size) { $size = $stream.length }
    $done = ($meta.pos - $section._.datapos) / $size
    <# and update remaining time every 1sec #>
    if (!$print['progress'] -or $tick - $print['progressmsgtick'] -ge 10000000) {
        $silentSeconds = ($tick - $print.tick)/10000000
        $remain = $silentSeconds / $done - $silentSeconds + 0.5
        <# smooth-average the remaining time #>
        $print.progressremain =
            if (!$print['progress']) { $remain }
            else { ($print.progressremain + $remain) / 2 }
        $action = @('Reading', 'Skipping')[!!$meta['skipped']]
        <# show level-1 section name to avoid flicker of alternate subcontainers #>
        $print.progress = "$action $($meta.path -replace '^/\w+/(\w+).*','$1') elements..."
        $print.progressmsgtick = $tick
    }
    write-progress $print.progress `
        -percent ([math]::min($done * 100, 100)) `
        -seconds ([Math]::min($print.progressremain, [int32]::maxValue))
}

#endregion
#region INDEXING

function indexMKV {

    function snapFPS([float]$fps) {
        forEach ($f in 18,24,25,30,48,60,120) {
            forEach ($div in 1, 1.001) {
                if ([math]::abs($fps - $f/$div) -le 0.001) {
                    return $f/$div
                }
            }
        }
        if ([math]::abs($fps - [int]$fps) -le 0.001) {
            return [int]$fps
        }
        $fps
    }
    function addFPSspan {
        if ($spanDur = $spanEndTime - $spanStartTime) {
            $fps = snapFPS (($spanEnd - 1 - $spanStart) / ($spanDur*$tcScale) * 1000)
        } else {
            $fps = [float]::PositiveInfinity
        }
        $mkv.timecodeSpans[[object]$spanStart] = @{
            time = [timespan]::new($spanStartTime * $tcScale * 10000)
            fps = $fps
        }
        sv spanStart ($spanEnd - 1) -scope 1
        sv spanStartTime $spanEndTime -scope 1
    }

    if (!$mkv.Segment[0] -or !$mkv.Segment[0].Tracks -or !$mkv.Segment[0].Tracks.Video) {
        write-warning 'Video tracks not found'
        return
    }
    $bin = $bin
    $stream = $stream
    $VINT = [byte[]]::new(8)
    $vidtrack = $mkv.Segment[0].Tracks.Video.TrackNumber
    $vidtrackVINT = $vidtrack -bor 0x80
    $tcScale = $mkv.Segment[0].Info[0]['TimecodeScale'] / 1000000 # scale mkv block time to ms

    $getKF = $opt.get['keyframes']
    $getTC = $opt.get['timecodes']
    $useCFR = $opt.get['useCFR']
    $timecodes = [Collections.Generic.SortedSet[uint64]]::new()
    $keyframes = [Collections.ArrayList]::new()

    if ($useCFR) {
        if (!$mkv.Segment[0]['Cues']) {
            write-warning 'Cues not found'
            return
        }
        $frameDur = $mkv.Segment.Tracks.Video._.find('DefaultDuration')
        if (!$frameDur) {
            write-warning 'No default video frame duration found'
            return
        }
        $frameDur = $frameDur._.rawValue/1000000 # ms
        $threshold = 1 / $frameDur # frame number rounding error for 1ms
        $timecodes.add(0) >$null

        $DTDcuepoint = $DTD.Segment.Cues.CuePoint
        $IDCuePoint = $DTDcuepoint._.id
        $IDCueTime = $DTDcuepoint.CueTime._.id
        $IDCueTrackPositions = $DTDcuepoint.CueTrackPositions._.id
        $IDCueTrack = $DTDcuepoint.CueTrackPositions.CueTrack._.id

        $time = $track = 0
        $cueEnd = [uint64]::maxValue

        $stream.position = $mkv.Segment.Cues._.datapos
        while ($stream.position -lt $stream.length) {
            # read ID
            $VINT.clear()
            $b = $VINT[0] = $bin.readByte()
            $id = if ($b -ge 0x80) {
                    $b
                } else {
                    $len = 8 - [byte][Math]::floor([Math]::log($b)/[Math]::log(2))
                    $bin.read($VINT, 1, $len - 1) >$null
                    [Array]::reverse($VINT, 0, $len)
                    [BitConverter]::toUInt64($VINT, 0)
                }
            # read size
            $VINT.clear()
            $b = $VINT[0] = $bin.readByte()
            $size = if ($b -ge 0x80) {
                    $b -band 0x7F
                } else {
                    $len = 8 - [byte][Math]::floor([Math]::log($b)/[Math]::log(2))
                    $VINT[0] = $b -band -bnot (1 -shl (8-$len))
                    $bin.read($VINT, 1, $len - 1) >$null
                    [Array]::reverse($VINT, 0, $len)
                    [BitConverter]::toUInt64($VINT, 0)
                }

            if ($id -eq $IDCueTime) {
                # read UINT
                $VINT.clear()
                $bin.read($VINT, 0, $size) >$null
                [Array]::reverse($VINT, 0, $size)
                $time = [BitConverter]::toUInt64($VINT, 0)
            }
            elseif ($id -eq $IDCueTrack) {
                if ($size -eq 1) {
                    $track = $bin.readByte()
                } else {
                    $VINT.clear()
                    $bin.read($VINT, 0, $size) >$null
                    [Array]::reverse($VINT, 0, $size)
                    $track = [BitConverter]::toUInt64($VINT, 0)
                }
            }
            elseif ($id -eq $IDCuePoint) {
                $time = $track = $null
                $cueEnd = $stream.position + $size
            }
            elseif ($id -ne $IDCueTrackPositions) {
                $stream.position += $size
            }

            if ($stream.position -ge $cueEnd -and $track -eq $vidtrack) {
                $ms = $time * $tcScale
                $frame = $ms / $frameDur
                if ($frame -lt 0 -or [math]::abs($frame - [uint64]$frame) -gt $threshold) {
                    write-warning "Got irregular time $([timespan]::new($ms*10000)), CFR mode cannot be used"
                    return
                }
                $keyframes.add([uint64]$frame) >$null
            }
        }
    } else {
        if (!$mkv.Segment[0].Cluster[0]) {
            write-warning 'Clusters not found'
            return
        }
        $DTDcluster = $DTD.Segment.Cluster
        $IDCluster = $DTDcluster._.id
        $IDTimecode = $DTDcluster.Timecode._.id
        $IDSimpleBlock = $DTDcluster.SimpleBlock._.id
        $IDBlockGroup = $DTDcluster.BlockGroup._.id
        $IDBlock = $DTDcluster.BlockGroup.Block._.id
        $IDReferenceBlock = $DTDcluster.BlockGroup.ReferenceBlock._.id

        $curBlock = 0
        $blockIsVideo = $false
        $blockGroupVideoEnd = [uint64]::maxValue
        $blockGroupVideoRef = $false
        $clusterTime = 0

        $tick0 = [datetime]::now.ticks
        $stream.position = $mkv.Segment[0].Cluster[0]._.datapos

        while ($stream.position -lt $stream.length) {
            # read ID
            $VINT.clear()
            $b = $VINT[0] = $bin.readByte()
            $id = if ($b -ge 0x80) {
                    $b
                } else {
                    $len = 8 - [byte][Math]::floor([Math]::log($b)/[Math]::log(2))
                    $bin.read($VINT, 1, $len - 1) >$null
                    [Array]::reverse($VINT, 0, $len)
                    [BitConverter]::toUInt64($VINT, 0)
                }
            # read size
            $VINT.clear()
            $b = $VINT[0] = $bin.readByte()
            $size = if ($b -ge 0x80) {
                    $b -band 0x7F
                } else {
                    $len = 8 - [byte][Math]::floor([Math]::log($b)/[Math]::log(2))
                    $VINT[0] = $b -band -bnot (1 -shl (8-$len))
                    $bin.read($VINT, 1, $len - 1) >$null
                    [Array]::reverse($VINT, 0, $len)
                    [BitConverter]::toUInt64($VINT, 0)
                }

            $datapos = $stream.position

            if ($id -eq $IDBlock) {
                $bin.read($VINT, 0, 4) >$null
                if ($blockIsVideo = $VINT[0] -eq $vidtrackVINT) {
                    $blockGroupVideoEnd = $blockGroupEnd
                    $blockGroupVideoRef = $blockGroupRef

                    if ($getTC) {
                        [Array]::reverse($VINT, 1, 2)
                        $timecodes.add($clusterTime + [BitConverter]::toInt16($VINT, 1)) >$null
                    }

                    $curBlock++
                }
            }
            elseif ($id -eq $IDReferenceBlock) {
                $blockGroupRef = $true
                if ($blockIsVideo) {
                    $blockGroupVideoEnd = $blockGroupEnd
                    $blockGroupVideoRef = $blockGroupRef
                }
            }
            elseif ($id -eq $IDSimpleBlock) {
                $bin.read($VINT, 0, 4) >$null
                if ($VINT[0] -eq $vidtrackVINT) {
                    if ($getTC) {
                        [Array]::reverse($VINT, 1, 2)
                        $timecodes.add($clusterTime + [BitConverter]::toInt16($VINT, 1)) >$null
                    }

                    if ($getKF -and $VINT[3] -ge 0x80) {
                        $keyframes.add($curBlock) >$null
                    }

                    $curBlock++
                }
            }
            elseif ($id -eq $IDCluster) {
                $size = 0
            }
            elseif ($id -eq $IDTimecode -and $getTC) {
                # read UINT
                $VINT.clear()
                $bin.read($VINT, 0, $size) >$null
                [Array]::reverse($VINT, 0, $size)
                $clusterTime = [BitConverter]::toUInt64($VINT, 0)
            }
            elseif ($id -eq $IDBlockGroup) {
                $blockGroupEnd = $datapos + $size
                $blockGroupRef = $false
                $blockIsVideo = $false
                $size = 0
            }

            $stream.position = $datapos + $size
            if ($getKF -and $stream.position -ge $blockGroupVideoEnd -and !$blockGroupVideoRef) {
                $keyframes.add($curBlock - 1) >$null
                $blockGroupVideoEnd = [uint64]::maxValue
            }

            if ($curBlock%1000 -eq 1 -and $opt.showProgress) {
                $progress = [Math]::max(0.000001, $stream.position / $stream.length)
                $elapsed = ([datetime]::now.ticks - $tick0)/10000000
                $remaining = $elapsed / $progress - $elapsed + 0.5
                $status = if ($keyframes.count) { 'Last keyframe: ' + $keyframes[-1] } else { 'Last frame: ' + $curBlock }
                write-progress 'Indexing..' -status $status -percent ($progress*100) -seconds $remaining
            }
        }
    }

    if ($timecodes.count -eq 1) {
        if ($dur = $mkv.Segment.Tracks.Video._.find('DefaultDuration')) {
            $mkv.timecodeSpans = [ordered]@{
                0 = @{
                    fps = snapFPS (1000 / $dur._.rawValue * 1000000)
                    time = [timespan]::new(0)
                }
            }
        }
    }

    if ($timecodes.count -gt 1) {
        if ($opt.showProgress) {
            write-progress 'Indexing..' -status 'Finding same FPS ranges' -percent 100
        }
        $mkv.timecodeSpans = [ordered]@{}
        $spanStart = $spanStartTime = $spanEnd = $spanEndTime = $lastDur = 0
        $threshold = 1 / $tcScale # 1ms
        forEach ($time in $timecodes) {
            $dur = $time - $spanEndTime
            $diff = $dur - $lastDur
            $fpschanged = ($diff -lt 0 -and $diff -lt -$threshold) -or ($diff -gt 0 -and $diff -gt $threshold)
            if ($fpschanged -and $spanEnd -gt 1) {
                addFPSspan
            }
            $lastDur = $dur
            $spanEndTime = $time
            $spanEnd++
        }
        # handle fps change right before the last frame
        if (($fpschanged -and $spanStart -eq $timecodes.count-2) -or $spanStart -eq 0) {
            addFPSspan
        }
    }

    if ($opt.showProgress) {
        write-progress 'Indexing..' -completed
    }

    if ($getTC -and !$useCFR) { $mkv.timecodes = $timecodes }
    if ($getKF) { $mkv.keyframes = $keyframes }
}

#endregion
#region INIT

function init {

    function addReverseMapping([hashtable]$container, [string]$path='/') {

        $meta = $container._
        $meta.IDs = [Collections.Generic.Dictionary[uint64,object]]::new()
        $DTD._.pathIDs[$path] = $meta.IDs

        if ($meta['recursiveNesting']) {
            $meta.IDs[$meta.id] = $container
        }

        forEach ($child in $container.getEnumerator()) {
            if ($child.key -ne '_') {
                $v = $child.value
                $childMeta = $v._
                $childMeta.name = $child.key
                $meta.IDs[$childMeta.id] = $v

                if ($childMeta['global']) {
                    $DTD._.globalIDs[$childMeta.id] = $v
                }

                if ($v.count -gt 1) {
                    addReverseMapping $v ($path + $child.key + '/')
                }
            }
        }
    }

    # postpone printing these small sections until all contained info is known
    $script:printPostponed = [regex]'/(Info|Tracks|ChapterAtom|Tag|EditionEntry|CuePoint)/$'
    $script:printPretty = [regex](
        '/Segment/$|' +
        '/Info/(TimecodeScale|SegmentUID)$|' +
        '/Tracks/TrackEntry/(|' +
            'Video/(|(Pixel|Display)(Width|Height)|FlagInterlaced)|' +
            'Audio/(|(Output)?SamplingFrequency|Channels|BitDepth)|' +
            'Track(Number|UID|Type)|Codec(ID|Private)|Language|Name|DefaultDuration|MinCache|' +
            'Flag(Lacing|Default|Forced|Enabled)|CodecDecodeAll|MaxBlockAdditionID|TrackTimecodeScale' +
        ')$|' +
        '/Chapters/EditionEntry/(' +
            'EditionUID|EditionFlag(Hidden|Default|Ordered)|' +
            'ChapterAtom/(|' +
                'Chapter(' +
                    'Display/(|Chap(String|Language|Country))|' +
                    'UID|Time(Start|End)|Flag(Hidden|Enabled)' +
                ')' +
            ')' +
        ')$|' +
        '/Attachments/AttachedFile/|' +
        '/Tags/Tag/|' +
        '/SeekHead/|' +
        '/EBML/|' +
        '/Void\b|' +
        '/CuePoint/'
    )
    $script:numberFormat = [Globalization.CultureInfo]::InvariantCulture
    $script:lookupChunkSize = 4096

    $script:dummyMeta = @{}

    add-member scriptMethod closest {
        # finds the closest parent
        param(
            [string]$name='', # name string, case-insensitive, takes precedence over 'match'
            [string]$match='' # path regexp, case-insensitive
        )
        for ($m = $this; $m['name']; $m = $m.parent._) {
            if (($name -and $m.name -eq $name) `
            -or ($match -and $m.path -match $match)) {
                return $m.ref
            }
        }
    } -inputObject $dummyMeta

    add-member scriptMethod find {
        # finds all nested children
        # returns: $null, a single object of primitive type or an array of 1 or more entries
        param(
            [string]$name='', # name string, case-insensitive, takes precedence over 'match'
            [string]$match='' # path regexp, case-insensitive
        )
        if ($this.ref -isnot [hashtable]) {
            return
        }
        $results = [ordered]@{}
        forEach ($child in $this.ref.getEnumerator()) {
            forEach ($meta in $child.value._) {
                if (($name -and $meta.name -eq $name) `
                -or ($match -and $meta.path -match $match)) {
                    $hash = '' + [Runtime.CompilerServices.RuntimeHelpers]::getHashCode($meta.ref)
                    if (!$results.contains($hash)) {
                        $results[$hash] = $meta.ref
                    }
                }
                if ($meta.type -eq 'container') {
                    forEach ($r in $meta.find($name,$match,0xDEADBEEF).getEnumerator()) {
                        $results[$r.name] = $r.value
                    }
                }
            }
        }
        if ($args -eq 0xDEADBEEF) { $results }
        elseif ($results.count -eq 0) { $null }
        elseif ($results.count -gt 1) { $results.values }
        elseif ($results.values[0]._.type -in 'binary','container') { ,$results.values[0] }
        else { $results.values[0] }
    } -inputObject $dummyMeta

    $script:dummyContainer = add-member _ $dummyMeta -inputObject (@{}) -passthru

    $script:colors = @{
        bold = 'white'
        normal = 'gray'
        dim = 'darkgray'

        container = 'white'
        string = 'green'
        stringdim = 'darkgreen'
        stringdim2 = 'darkcyan' # custom simple tag
        value = 'yellow'

        reference = 'cyan' # referenced track name in Tags
    }

    $script:DTD = @{
        _=@{
            pathIDs = [ordered]@{}
            globalIDs = [Collections.Generic.Dictionary[uint64,object]]::new()
            trackTypes = @{
                   1 = 'Video'
                   2 = 'Audio'
                0x10 = 'Logo'
                0x11 = 'Subtitle'
                0x12 = 'Buttons'
                0x20 = 'Control'
            }
        }

        CRC32 = @{ _=@{ id=0xbf; type='binary'; global=$true } }
        Void = @{ _=@{ id=0xec; type='binary'; global=$true; multiple=$true } }
        SignatureSlot = @{ _=@{ id=0x1b538667; type='container'; global=$true; multiple=$true }
            SignatureAlgo = @{ _=@{ id=0x7e8a; type='uint' } }
            SignatureHash = @{ _=@{ id=0x7e9a; type='uint' } }
            SignaturePublicKey = @{ _=@{ id=0x7ea5; type='binary' } }
            Signature = @{ _=@{ id=0x7eb5; type='binary' } }
            SignatureElements = @{ _=@{ id=0x7e5b; type='container' }
                SignatureElementList = @{ _=@{ id=0x7e7b; type='container'; multiple=$true }
                    SignedElement = @{ _=@{ id=0x6532; type='binary'; multiple=$true } }
                }
            }
        }

        EBML = @{ _=@{ id=0x1a45dfa3; type='container'; multiple=$true }
            EBMLVersion = @{ _=@{ id=0x4286; type='uint'; value=1 } }
            EBMLReadVersion = @{ _=@{ id=0x42f7; type='uint'; value=1 } }
            EBMLMaxIDLength = @{ _=@{ id=0x42f2; type='uint'; value=4 } }
            EBMLMaxSizeLength = @{ _=@{ id=0x42f3; type='uint'; value=8 } }
            DocType = @{ _=@{ id=0x4282; type='string' } }
            DocTypeVersion = @{ _=@{ id=0x4287; type='uint'; value=1 } }
            DocTypeReadVersion = @{ _=@{ id=0x4285; type='uint'; value=1 } }
        }

        # Matroska DTD
        Segment = @{ _=@{ id=0x18538067; type='container'; multiple=$true }

            # Meta Seek Information
            SeekHead = @{ _=@{ id=0x114d9b74; type='container'; multiple=$true }
                Seek = @{ _=@{ id=0x4dbb; type='container'; multiple=$true }
                    SeekID = @{ _=@{ id=0x53ab; type='binary' } }
                    SeekPosition = @{ _=@{ id=0x53ac; type='uint' } }
                }
            }

            # Segment Information
            Info = @{ _=@{ id=0x1549a966; type='container'; multiple=$true }
                SegmentUID = @{ _=@{ id=0x73a4; type='binary' } }
                SegmentFilename = @{ _=@{ id=0x7384; type='string' } }
                PrevUID = @{ _=@{ id=0x3cb923; type='binary' } }
                PrevFilename = @{ _=@{ id=0x3c83ab; type='string' } }
                NextUID = @{ _=@{ id=0x3eb923; type='binary' } }
                NextFilename = @{ _=@{ id=0x3e83bb; type='string' } }
                SegmentFamily = @{ _=@{ id=0x4444; type='binary'; multiple=$true } }
                ChapterTranslate = @{ _=@{ id=0x6924; type='container'; multiple=$true }
                    ChapterTranslateEditionUID = @{ _=@{ id=0x69fc; type='uint'; multiple=$true } }
                    ChapterTranslateCodec = @{ _=@{ id=0x69bf; type='uint' } }
                    ChapterTranslateID = @{ _=@{ id=0x69a5; type='binary' } }
                }
                TimecodeScale = @{ _=@{ id=0x2ad7b1; type='uint'; value=1000000 } }
                Duration = @{ _=@{ id=0x4489; type='float' } }
                DateUTC = @{ _=@{ id=0x4461; type='date' } }
                Title = @{ _=@{ id=0x7ba9; type='string' } }
                MuxingApp = @{ _=@{ id=0x4d80; type='string' } }
                WritingApp = @{ _=@{ id=0x5741; type='string' } }
            }

            # Cluster
            Cluster = @{ _=@{ id=0x1f43b675; type='container'; multiple=$true }
                Timecode = @{ _=@{ id=0xe7; type='uint' } }
                SilentTracks = @{ _=@{ id=0x5854; type='container' }
                    SilentTrackNumber = @{ _=@{ id=0x58d7; type='uint'; multiple=$true } }
                }
                Position = @{ _=@{ id=0xa7; type='uint' } }
                PrevSize = @{ _=@{ id=0xab; type='uint' } }
                SimpleBlock = @{ _=@{ id=0xa3; type='binary'; multiple=$true } }
                BlockGroup = @{ _=@{ id=0xa0; type='container'; multiple=$true }
                    Block = @{ _=@{ id=0xa1; type='binary' } }
                    BlockVirtual = @{ _=@{ id=0xa2; type='binary' } }
                    BlockAdditions = @{ _=@{ id=0x75a1; type='container' }
                        BlockMore = @{ _=@{ id=0xa6; type='container'; multiple=$true }
                            BlockAddID = @{ _=@{ id=0xee; type='uint' } }
                            BlockAdditional = @{ _=@{ id=0xa5; type='binary' } }
                        }
                    }
                    BlockDuration = @{ _=@{ id=0x9b; type='uint' } }
                    ReferencePriority = @{ _=@{ id=0xfa; type='uint' } }
                    ReferenceBlock = @{ _=@{ id=0xfb; type='int'; multiple=$true } }
                    ReferenceVirtual = @{ _=@{ id=0xfd; type='int' } }
                    CodecState = @{ _=@{ id=0xa4; type='binary' } }
                    DiscardPadding = @{ _=@{ id=0x75a2; type='int' } }
                    Slices = @{ _=@{ id=0x8e; type='container' }
                        TimeSlice = @{ _=@{ id=0xe8; type='container'; multiple=$true }
                            LaceNumber = @{ _=@{ id=0xcc; type='uint'; value=0 } }
                            FrameNumber = @{ _=@{ id=0xcd; type='uint'; value=0 } }
                            BlockAdditionID = @{ _=@{ id=0xcb; type='uint'; value=0 } }
                            Delay = @{ _=@{ id=0xce; type='uint'; value=0 } }
                            SliceDuration = @{ _=@{ id=0xcf; type='uint' } }
                        }
                    }
                    ReferenceFrame = @{ _=@{ id=0xc8; type='container' }
                        ReferenceOffset = @{ _=@{ id=0xc9; type='uint'; value=0 } }
                        ReferenceTimeCode = @{ _=@{ id=0xca; type='uint'; value=0 } }
                    }
                EncryptedBlock = @{ _=@{ id=0xaf; type='binary'; multiple=$true } }
                }
            }

            # Track
            Tracks = @{ _=@{ id=0x1654ae6b; type='container'; multiple=$true }
                TrackEntry = @{ _=@{ id=0xae; type='container'; multiple=$true }
                    TrackNumber = @{ _=@{ id=0xd7; type='uint' } }
                    TrackUID = @{ _=@{ id=0x73c5; type='uint' } }
                    TrackType = @{ _=@{ id=0x83; type='uint' } }
                    FlagEnabled = @{ _=@{ id=0xb9; type='uint'; value=1 } }
                    FlagDefault = @{ _=@{ id=0x88; type='uint'; value=1 } }
                    FlagForced = @{ _=@{ id=0x55aa; type='uint'; value=0 } }
                    FlagLacing = @{ _=@{ id=0x9c; type='uint'; value=1 } }
                    MinCache = @{ _=@{ id=0x6de7; type='uint'; value=0 } }
                    MaxCache = @{ _=@{ id=0x6df8; type='uint' } }
                    DefaultDuration = @{ _=@{ id=0x23e383; type='uint' } }
                    DefaultDecodedFieldDuration = @{ _=@{ id=0x234e7a; type='uint' } }
                    TrackTimecodeScale = @{ _=@{ id=0x23314f; type='float'; value=1.0 } }
                    TrackOffset = @{ _=@{ id=0x537f; type='int'; value=0 } }
                    MaxBlockAdditionID = @{ _=@{ id=0x55ee; type='uint'; value=0 } }
                    Name = @{ _=@{ id=0x536e; type='string' } }
                    Language = @{ _=@{ id=0x22b59c; type='string'; value='eng' } }
                    CodecID = @{ _=@{ id=0x86; type='string' } }
                    CodecPrivate = @{ _=@{ id=0x63a2; type='binary' } }
                    CodecName = @{ _=@{ id=0x258688; type='string' } }
                    AttachmentLink = @{ _=@{ id=0x7446; type='uint' } }
                    CodecSettings = @{ _=@{ id=0x3a9697; type='string' } }
                    CodecInfoURL = @{ _=@{ id=0x3b4040; type='string'; multiple=$true } }
                    CodecDownloadURL = @{ _=@{ id=0x26b240; type='string'; multiple=$true } }
                    CodecDecodeAll = @{ _=@{ id=0xaa; type='uint'; value=1 } }
                    TrackOverlay = @{ _=@{ id=0x6fab; type='uint'; multiple=$true } }
                    CodecDelay = @{ _=@{ id=0x56aa; type='uint' } }
                    SeekPreRoll = @{ _=@{ id=0x56bb; type='uint' } }
                    TrackTranslate = @{ _=@{ id=0x6624; type='container'; multiple=$true }
                        TrackTranslateEditionUID = @{ _=@{ id=0x66fc; type='uint'; multiple=$true } }
                        TrackTranslateCodec = @{ _=@{ id=0x66bf; type='uint' } }
                        TrackTranslateTrackID = @{ _=@{ id=0x66a5; type='binary' } }
                    }

                    # Video
                    Video = @{ _=@{ id=0xe0; type='container' }
                        FlagInterlaced = @{ _=@{ id=0x9a; type='uint'; value=0 } }
                        StereoMode = @{ _=@{ id=0x53b8; type='uint'; value=0 } }
                        AlphaMode = @{ _=@{ id=0x53c0; type='uint' } }
                        OldStereoMode = @{ _=@{ id=0x53b9; type='uint' } }
                        PixelWidth = @{ _=@{ id=0xb0; type='uint' } }
                        PixelHeight = @{ _=@{ id=0xba; type='uint' } }
                        PixelCropBottom = @{ _=@{ id=0x54aa; type='uint' } }
                        PixelCropTop = @{ _=@{ id=0x54bb; type='uint' } }
                        PixelCropLeft = @{ _=@{ id=0x54cc; type='uint' } }
                        PixelCropRight = @{ _=@{ id=0x54dd; type='uint' } }
                        DisplayWidth = @{ _=@{ id=0x54b0; type='uint' } }
                        DisplayHeight = @{ _=@{ id=0x54ba; type='uint' } }
                        DisplayUnit = @{ _=@{ id=0x54b2; type='uint'; value=0 } }
                        AspectRatioType = @{ _=@{ id=0x54b3; type='uint'; value=0 } }
                        ColourSpace = @{ _=@{ id=0x2eb524; type='binary' } }
                        GammaValue = @{ _=@{ id=0x2fb523; type='float' } }
                        FrameRate = @{ _=@{ id=0x2383e3; type='float' } }
                    }

                    # Audio
                    Audio = @{ _=@{ id=0xe1; type='container' }
                        SamplingFrequency = @{ _=@{ id=0xb5; type='float'; value=8000.0 } }
                        OutputSamplingFrequency = @{ _=@{ id=0x78b5; type='float'; value=8000.0 } }
                        Channels = @{ _=@{ id=0x9f; type='uint'; value=1 } }
                        ChannelPositions = @{ _=@{ id=0x7d7b; type='binary' } }
                        BitDepth = @{ _=@{ id=0x6264; type='uint' } }
                    }

                    TrackOperation = @{ _=@{ id=0xe2; type='container' }
                        TrackCombinePlanes = @{ _=@{ id=0xe3; type='container' }
                            TrackPlane = @{ _=@{ id=0xe4; type='container'; multiple=$true }
                                TrackPlaneUID = @{ _=@{ id=0xe5; type='uint' } }
                                TrackPlaneType = @{ _=@{ id=0xe6; type='uint' } }
                            }
                        }
                        TrackJoinBlocks = @{ _=@{ id=0xe9; type='container' }
                            TrackJoinUID = @{ _=@{ id=0xed; type='uint'; multiple=$true } }
                        }
                    }

                    TrickTrackUID = @{ _=@{ id=0xc0; type='uint' } }
                    TrickTrackSegmentUID = @{ _=@{ id=0xc1; type='binary' } }
                    TrickTrackFlag = @{ _=@{ id=0xc6; type='uint' } }
                    TrickMasterTrackUID = @{ _=@{ id=0xc7; type='uint' } }
                    TrickMasterTrackSegmentUID = @{ _=@{ id=0xc4; type='binary' } }

                    # Content Encoding
                    ContentEncodings = @{ _=@{ id=0x6d80; type='container' }
                        ContentEncoding = @{ _=@{ id=0x6240; type='container'; multiple=$true }
                            ContentEncodingOrder = @{ _=@{ id=0x5031; type='uint'; value=0 } }
                            ContentEncodingScope = @{ _=@{ id=0x5032; type='uint'; value=1 } }
                            ContentEncodingType = @{ _=@{ id=0x5033; type='uint' } }
                            ContentCompression = @{ _=@{ id=0x5034; type='container' }
                                ContentCompAlgo = @{ _=@{ id=0x4254; type='uint'; value=0 } }
                                ContentCompSettings = @{ _=@{ id=0x4255; type='binary' } }
                            }
                            ContentEncryption = @{ _=@{ id=0x5035; type='container' }
                                ContentEncAlgo = @{ _=@{ id=0x47e1; type='uint'; value=0 } }
                                ContentEncKeyID = @{ _=@{ id=0x47e2; type='binary' } }
                                ContentSignature = @{ _=@{ id=0x47e3; type='binary' } }
                                ContentSigKeyID = @{ _=@{ id=0x47e4; type='binary' } }
                                ContentSigAlgo = @{ _=@{ id=0x47e5; type='uint' } }
                                ContentSigHashAlgo = @{ _=@{ id=0x47e6; type='uint' } }
                            }
                        }
                    }
                }
            }

            # Cueing Data
            Cues = @{ _=@{ id=0x1c53bb6b; type='container' }
                CuePoint = @{ _=@{ id=0xbb; type='container'; multiple=$true }
                    CueTime = @{ _=@{ id=0xb3; type='uint' } }
                    CueTrackPositions = @{ _=@{ id=0xb7; type='container'; multiple=$true }
                        CueTrack = @{ _=@{ id=0xf7; type='uint' } }
                        CueClusterPosition = @{ _=@{ id=0xf1; type='uint' } }
                        CueRelativePosition = @{ _=@{ id=0xf0; type='uint' } }
                        CueDuration = @{ _=@{ id=0xb2; type='uint' } }
                        CueBlockNumber = @{ _=@{ id=0x5378; type='uint'; value=1 } }
                        CueCodecState = @{ _=@{ id=0xea; type='uint'; value=0 } }
                        CueReference = @{ _=@{ id=0xdb; type='container'; multiple=$true }
                            CueRefTime = @{ _=@{ id=0x96; type='uint' } }
                            CueRefCluster = @{ _=@{ id=0x97; type='uint' } }
                            CueRefNumber = @{ _=@{ id=0x535f; type='uint'; value=1 } }
                            CueRefCodecState = @{ _=@{ id=0xeb; type='uint'; value=0 } }
                        }
                    }
                }
            }

            # Attachment
            Attachments = @{ _=@{ id=0x1941a469; type='container' }
                AttachedFile = @{ _=@{ id=0x61a7; type='container'; multiple=$true }
                    FileDescription = @{ _=@{ id=0x467e; type='string' } }
                    FileName = @{ _=@{ id=0x466e; type='string' } }
                    FileMimeType = @{ _=@{ id=0x4660; type='string' } }
                    FileData = @{ _=@{ id=0x465c; type='binary' } }
                    FileUID = @{ _=@{ id=0x46ae; type='uint' } }
                    FileReferral = @{ _=@{ id=0x4675; type='binary' } }
                    FileUsedStartTime = @{ _=@{ id=0x4661; type='uint' } }
                    FileUsedEndTime = @{ _=@{ id=0x4662; type='uint' } }
                }
            }

            # Chapters
            Chapters = @{ _=@{ id=0x1043a770; type='container' }
                EditionEntry = @{ _=@{ id=0x45b9; type='container'; multiple=$true }
                    EditionUID = @{ _=@{ id=0x45bc; type='uint' } }
                    EditionFlagHidden = @{ _=@{ id=0x45bd; type='uint' } }
                    EditionFlagDefault = @{ _=@{ id=0x45db; type='uint' } }
                    EditionFlagOrdered = @{ _=@{ id=0x45dd; type='uint' } }
                    ChapterAtom = @{ _=@{ id=0xb6; type='container'; multiple=$true; recursiveNesting=$true }
                        ChapterUID = @{ _=@{ id=0x73c4; type='uint' } }
                        ChapterStringUID = @{ _=@{ id=0x5654; type='binary' } }
                        ChapterTimeStart = @{ _=@{ id=0x91; type='uint' } }
                        ChapterTimeEnd = @{ _=@{ id=0x92; type='uint' } }
                        ChapterFlagHidden = @{ _=@{ id=0x98; type='uint'; value=0 } }
                        ChapterFlagEnabled = @{ _=@{ id=0x4598; type='uint'; value=0 } }
                        ChapterSegmentUID = @{ _=@{ id=0x6e67; type='binary' } }
                        ChapterSegmentEditionUID = @{ _=@{ id=0x6ebc; type='uint' } }
                        ChapterPhysicalEquiv = @{ _=@{ id=0x63c3; type='uint' } }
                        ChapterTrack = @{ _=@{ id=0x8f; type='container' }
                            ChapterTrackNumber = @{ _=@{ id=0x89; multiple=$true; type='uint' } }
                        }
                        ChapterDisplay = @{ _=@{ id=0x80; type='container'; multiple=$true }
                            ChapString = @{ _=@{ id=0x85; type='string' } }
                            ChapLanguage = @{ _=@{ id=0x437c; type='string'; multiple=$true; value='eng' } }
                            ChapCountry = @{ _=@{ id=0x437e; type='string'; multiple=$true } }
                        }
                        ChapProcess = @{ _=@{ id=0x6944; type='container'; multiple=$true }
                            ChapProcessCodecID = @{ _=@{ id=0x6955; type='uint' } }
                            ChapProcessPrivate = @{ _=@{ id=0x450d; type='binary' } }
                            ChapProcessCommand = @{ _=@{ id=0x6911; type='container'; multiple=$true }
                                ChapProcessTime = @{ _=@{ id=0x6922; type='uint' } }
                                ChapProcessData = @{ _=@{ id=0x6933; type='binary' } }
                            }
                        }
                    }
                }
            }

            # Tagging
            Tags = @{ _=@{ id=0x1254c367; type='container'; multiple=$true }
                Tag = @{ _=@{ id=0x7373; type='container'; multiple=$true }
                    Targets = @{ _=@{ id=0x63c0; type='container' }
                        TargetTypeValue = @{ _=@{ id=0x68ca; type='uint' } }
                        TargetType = @{ _=@{ id=0x63ca; type='string' } }
                        TagTrackUID = @{ _=@{ id=0x63c5; type='uint'; multiple=$true; value=0 } }
                        TagEditionUID = @{ _=@{ id=0x63c9; type='uint'; multiple=$true } }
                        TagChapterUID = @{ _=@{ id=0x63c4; type='uint'; multiple=$true; value=0 } }
                        TagAttachmentUID = @{ _=@{ id=0x63c6; type='uint'; multiple=$true; value=0 } }
                    }
                    SimpleTag = @{ _=@{ id=0x67c8; type='container'; multiple=$true; recursiveNesting=$true }
                        TagName = @{ _=@{ id=0x45a3; type='string' } }
                        TagLanguage = @{ _=@{ id=0x447a; type='string' } }
                        TagDefault = @{ _=@{ id=0x4484; type='uint' } }
                        TagString = @{ _=@{ id=0x4487; type='string' } }
                        TagBinary = @{ _=@{ id=0x4485; type='binary' } }
                    }
                }
            }
        }
    }

    addReverseMapping $DTD
}
#endregion

export-moduleMember -function parseMKV
