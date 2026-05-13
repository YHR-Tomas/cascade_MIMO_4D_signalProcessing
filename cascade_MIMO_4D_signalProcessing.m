function results = cascade_MIMO_4D_signalProcessing(varargin)
% cascade_MIMO_4D_signalProcessing
%
% Build a 4D cascade-MIMO data cube with the flow:
% raw ADC -> calibration -> range FFT -> Doppler FFT -> 2D beamforming
% -> Doppler compression -> polar cube -> Cartesian voxel grid
%
% Default output:
%   1. 4D radar tensor is processed internally as
%      [Doppler, Range, ElevationBin, AzimuthBin]
%   2. Compressed polar cube is returned as
%      [Range, ElevationBin, AzimuthBin]
%   3. Cartesian voxel cube is returned as
%      [X, Y, Z]
%
% Example:
%   results = cascade_MIMO_4D_signalProcessing( ...
%       'testID', 1, ...
%       'fileGroupIdx', 1, ...
%       'frameIdx', 2, ...
%       'dopplerCompressMethod', 'sum');

%    results = cascade_MIMO_4D_signalProcessing( ...
%        'testID', 1, ...
%        'captureRootDir', 'D:\RadarData', ...
%        'processAllCaptureFolders', 1, ...
%        'captureFolderPattern', 'Cascade_Capture_*', ...
%        'outputRootDir', 'D:\RadarOutput', ...
%        'saveOutput', 1, ...
%        'frameIdx', 2);




parser = inputParser;
parser.addParameter('testID', 1);
parser.addParameter('fileGroupIdx', 1);
parser.addParameter('frameIdx', 2);
parser.addParameter('plotOn', 0);
parser.addParameter('saveOutput', 0);
parser.addParameter('outputFile', '');
parser.addParameter('generateParamFile', 0);
parser.addParameter('configJsonFile', '');
parser.addParameter('store4DCube', 0);
parser.addParameter('dopplerCompressMethod', 'sum');
parser.addParameter('cartesianGridSize', [256 256 256]);
parser.addParameter('inputDataFolders', {});
parser.addParameter('outputRootDir', '');
parser.addParameter('captureRootDir', '');
parser.addParameter('captureFolderPattern', 'Cascade_Capture_*');
parser.addParameter('captureFolderNames', {});
parser.addParameter('processAllCaptureFolders', 0);
parser.addParameter('processAllFileGroups', 1);

if nargin == 0
    cfg = getDefaultRunConfig();
else
    parser.parse(varargin{:});
    cfg = parser.Results;
end

if numel(cfg.cartesianGridSize) ~= 3
    error('cartesianGridSize must be a 3-element vector [Nx Ny Nz].');
end

scriptDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(scriptDir));
setenv('CASCADE_SIGNAL_PROCESSING_CHAIN_MIMO', projectRoot);
run(fullfile(projectRoot, 'add_paths.m'));
inputPath = fullfile(scriptDir, 'input');
testListPath = fullfile(inputPath, 'testList.txt');

if ~exist(testListPath, 'file')
    error('testList.txt not found: %s', testListPath);
end

[dataFolderTest, dataFolderCalib, moduleParamFile] = getTestEntry(testListPath, cfg.testID);
baseGeneratedParamFile = fullfile(inputPath, sprintf('test%d_param.m', cfg.testID));
jsonGeneratedParamFile = fullfile(inputPath, sprintf('test%d_json_param.m', cfg.testID));
configJsonFile = resolveConfigJsonFile(cfg.configJsonFile, dataFolderTest, scriptDir);

if ~isempty(configJsonFile)
    generatedParamFile = jsonGeneratedParamFile;
    createParamFileFromJsonConfig(configJsonFile, dataFolderCalib, moduleParamFile, generatedParamFile, 'TDA2');
elseif cfg.generateParamFile
    warning(['No config JSON file was provided or found automatically. ', ...
             'Falling back to the existing generated test parameter file if available.']);
    generatedParamFile = baseGeneratedParamFile;
else
    generatedParamFile = baseGeneratedParamFile;
end

if exist(generatedParamFile, 'file') ~= 2
    error(['Generated parameter file not found: %s\n', ...
           'Provide configJsonFile, place a single *.mmwave.json beside the data, or prepare test%d_param.m first.'], ...
           generatedParamFile, cfg.testID);
end

captureFolders = resolveCaptureFolders(cfg, dataFolderTest);
if isempty(captureFolders)
    error('No capture folders were selected for processing.');
end

numCaptureFolders = numel(captureFolders);
fprintf('Detected %d capture folder(s) matching the current selection.\n', numCaptureFolders);

resultsCell = cell(1, numCaptureFolders);
for captureIdx = 1:numCaptureFolders
    currentFolder = captureFolders{captureIdx};
    fprintf('[%d/%d] Processing capture folder: %s\n', captureIdx, numCaptureFolders, currentFolder);
    resultsCell{captureIdx} = processSingleCaptureFolder( ...
        currentFolder, dataFolderCalib, generatedParamFile, configJsonFile, cfg, scriptDir, projectRoot);
end

if numel(resultsCell) == 1
    results = resultsCell{1};
else
    results = [resultsCell{:}];
end

end

function cfg = getDefaultRunConfig()
% EDIT THESE DEFAULTS IF YOU WANT TO PRESS RUN IN MATLAB DIRECTLY.
cfg = struct();
cfg.testID = 1;
cfg.fileGroupIdx = 1;
cfg.frameIdx = 2;
cfg.plotOn = 0;
cfg.saveOutput = 1;
cfg.outputFile = '';
cfg.generateParamFile = 0;
cfg.configJsonFile = '';
cfg.store4DCube = 0;
cfg.dopplerCompressMethod = 'sum';
cfg.cartesianGridSize = [256 256 256];
cfg.inputDataFolders = {};
cfg.outputRootDir = 'D:\1_school_result\radar_data\test_output_1';
cfg.captureRootDir = 'D:\1_school_result\radar_data';
cfg.captureFolderPattern = 'Cascade_Capture_*';
cfg.captureFolderNames = {};
cfg.processAllCaptureFolders = 1;
cfg.processAllFileGroups = 1;
end

function captureFolders = resolveCaptureFolders(cfg, defaultDataFolder)
if ~isempty(cfg.inputDataFolders)
    if ischar(cfg.inputDataFolders)
        captureFolders = {cfg.inputDataFolders};
    else
        captureFolders = cfg.inputDataFolders;
    end
    for idx = 1:numel(captureFolders)
        if exist(captureFolders{idx}, 'dir') ~= 7
            error('Input data folder not found: %s', captureFolders{idx});
        end
    end
    return;
end

if ~isempty(cfg.captureFolderNames)
    if ischar(cfg.captureFolderNames)
        folderNames = {cfg.captureFolderNames};
    else
        folderNames = cfg.captureFolderNames;
    end
    rootDir = cfg.captureRootDir;
    if isempty(rootDir)
        rootDir = fileparts(defaultDataFolder);
    end
    captureFolders = cell(1, numel(folderNames));
    for idx = 1:numel(folderNames)
        candidateFolder = folderNames{idx};
        if exist(candidateFolder, 'dir') == 7
            captureFolders{idx} = candidateFolder;
        else
            captureFolders{idx} = fullfile(rootDir, candidateFolder);
        end
        if exist(captureFolders{idx}, 'dir') ~= 7
            error('Capture folder not found: %s', captureFolders{idx});
        end
    end
    return;
end

if cfg.processAllCaptureFolders
    rootDir = cfg.captureRootDir;
    if isempty(rootDir)
        rootDir = fileparts(defaultDataFolder);
    end
    folderInfo = dir(fullfile(rootDir, cfg.captureFolderPattern));
    folderInfo = folderInfo([folderInfo.isdir]);
    folderInfo = folderInfo(~ismember({folderInfo.name}, {'.', '..'}));
    captureFolders = arrayfun(@(x) fullfile(rootDir, x.name), folderInfo, 'UniformOutput', false);
    captureFolders = sort(captureFolders);
    return;
end

captureFolders = {defaultDataFolder};
end

function results = processSingleCaptureFolder(dataFolderTest, dataFolderCalib, generatedParamFile, configJsonFile, cfg, scriptDir, projectRoot)
calibrationObj = calibrationCascade('pfile', generatedParamFile, 'calibrationfilePath', dataFolderCalib);
rangeFFTObj = rangeProcCascade('pfile', generatedParamFile);
DopplerFFTObj = DopplerProcClutterRemove('pfile', generatedParamFile);
DOAObj = DOACascade('pfile', generatedParamFile);

fileIdxUnique = getUniqueFileIdx(dataFolderTest);
if isempty(fileIdxUnique)
    error('No binary file groups were found in %s', dataFolderTest);
end

if cfg.processAllFileGroups
    fileGroupIndices = 1:numel(fileIdxUnique);
else
    if cfg.fileGroupIdx < 1 || cfg.fileGroupIdx > numel(fileIdxUnique)
        error('fileGroupIdx=%d is out of range. Available groups: 1..%d', cfg.fileGroupIdx, numel(fileIdxUnique));
    end
    fileGroupIndices = cfg.fileGroupIdx;
end

numFileGroups = numel(fileGroupIndices);
fprintf('Found %d file group(s) in %s.\n', numFileGroups, dataFolderTest);

fileGroupResultsCell = cell(1, numFileGroups);
for groupPos = 1:numFileGroups
    groupIdx = fileGroupIndices(groupPos);
    fprintf('  File group progress: %d/%d\n', groupPos, numFileGroups);
    fileNameStruct = getBinFileNames_withIdx(dataFolderTest, fileIdxUnique{groupIdx});
    [numValidFrames, ~] = getValidNumFrames(fullfile(dataFolderTest, fileNameStruct.masterIdxFile));
    if cfg.frameIdx < 1 || cfg.frameIdx > numValidFrames
        error('frameIdx=%d is out of range for %s. Valid frames: 1..%d', cfg.frameIdx, dataFolderTest, numValidFrames);
    end

    calibrationObj.binfilePath = fileNameStruct;
    calibrationObj.frameIdx = cfg.frameIdx;
    adcData = datapath(calibrationObj);
    adcData = adcData(:, :, calibrationObj.RxForMIMOProcess, :);

    tmpRange = datapath(rangeFFTObj, adcData(:, :, :, 1));
    tmpDoppler = datapath(DopplerFFTObj, tmpRange);
    rangeFFTOut = zeros([size(tmpRange), size(adcData, 4)], 'like', tmpRange);
    DopplerFFTOut = zeros([size(tmpDoppler), size(adcData, 4)], 'like', tmpDoppler);
    rangeFFTOut(:, :, :, 1) = tmpRange;
    DopplerFFTOut(:, :, :, 1) = tmpDoppler;
    for iTx = 2:size(adcData, 4)
        rangeFFTOut(:, :, :, iTx) = datapath(rangeFFTObj, adcData(:, :, :, iTx));
        DopplerFFTOut(:, :, :, iTx) = datapath(DopplerFFTObj, rangeFFTOut(:, :, :, iTx));
    end

    virtualArrayCube = reshape(DopplerFFTOut, size(DopplerFFTOut, 1), size(DopplerFFTOut, 2), []);
    numRangeBins = size(virtualArrayCube, 1);
    numDopplerBins = size(virtualArrayCube, 2);

    [linIdxKeep, apertureLenAz, apertureLenEl, keepMask] = buildVirtualArrayMap(DOAObj.D);
    virtualArrayCube = virtualArrayCube(:, :, keepMask);

    [azimuthGridDeg, elevationGridDeg, validAngleMask] = buildAngleGrid( ...
        DOAObj.DOAFFTSize, DOAObj.antDis, DOAObj.angles_DOA_az, DOAObj.angles_DOA_ele);

    polarCompressed = zeros(numRangeBins, DOAObj.DOAFFTSize, DOAObj.DOAFFTSize, 'single');
    store4D = logical(cfg.store4DCube);
    if store4D
        numElements4D = double(numDopplerBins) * double(numRangeBins) * ...
                        double(DOAObj.DOAFFTSize) * double(DOAObj.DOAFFTSize);
        estBytes = numElements4D * 4;
        if estBytes > 2e9
            warning(['Requested store4DCube=1 needs about %.2f GB as single precision. ', ...
                     'Disabling full 4D storage to avoid excessive memory use.'], estBytes / 2^30);
            store4D = false;
        end
    end

    if store4D
        fourDCube = zeros(numDopplerBins, numRangeBins, DOAObj.DOAFFTSize, DOAObj.DOAFFTSize, 'single');
    else
        fourDCube = [];
    end

    mask3D = repmat(validAngleMask.', 1, 1, numDopplerBins);
    for rangeIdx = 1:numRangeBins
        rangeSlice = squeeze(virtualArrayCube(rangeIdx, :, :)).';
        apertureCube = zeros(apertureLenAz * apertureLenEl, numDopplerBins, 'like', rangeSlice);
        apertureCube(linIdxKeep, :) = rangeSlice;
        apertureCube = reshape(apertureCube, apertureLenAz, apertureLenEl, numDopplerBins);

        angleCube = fftshift(fft(apertureCube, DOAObj.DOAFFTSize, 1), 1);
        angleCube = fftshift(fft(angleCube, DOAObj.DOAFFTSize, 2), 2);
        powerCube = abs(angleCube).^2;
        powerCube(~mask3D) = 0;

        if store4D
            fourDCube(:, rangeIdx, :, :) = permute(single(powerCube), [3 2 1]);
        end

        compressedMap = compressDoppler(powerCube, cfg.dopplerCompressMethod);
        polarCompressed(rangeIdx, :, :) = single(compressedMap.');
    end

    paramValues = readParamFileValues(generatedParamFile, {'rangeBinSize', 'velocityBinSize'});
    rangeBinSize = paramValues.rangeBinSize;
    velocityBinSize = paramValues.velocityBinSize;
    rangeAxisM = ((0:numRangeBins-1) * rangeBinSize).';
    dopplerAxisMps = ((0:numDopplerBins-1) - numDopplerBins / 2) * velocityBinSize;

    [cartesianCube, xAxisM, yAxisM, zAxisM] = polarToCartesian( ...
        polarCompressed, rangeAxisM, azimuthGridDeg, elevationGridDeg, cfg.cartesianGridSize);

    currentResult = struct();
    currentResult.config = cfg;
    currentResult.projectRoot = projectRoot;
    currentResult.generatedParamFile = generatedParamFile;
    currentResult.configJsonFileUsed = configJsonFile;
    currentResult.dataFolderTest = dataFolderTest;
    currentResult.dataFolderCalib = dataFolderCalib;
    currentResult.frameIdx = cfg.frameIdx;
    currentResult.fileGroupIdx = groupIdx;
    currentResult.fileGroupToken = fileIdxUnique{groupIdx};
    currentResult.numValidFrames = numValidFrames;
    currentResult.virtualAntennas = size(DopplerFFTOut, 3) * size(DopplerFFTOut, 4);
    currentResult.rangeBins = numRangeBins;
    currentResult.dopplerBins = numDopplerBins;
    currentResult.azimuthBins = DOAObj.DOAFFTSize;
    currentResult.elevationBins = DOAObj.DOAFFTSize;
    currentResult.axes = struct();
    currentResult.axes.range_m = rangeAxisM;
    currentResult.axes.doppler_mps = dopplerAxisMps(:);
    currentResult.axes.azimuth_deg = azimuthGridDeg;
    currentResult.axes.elevation_deg = elevationGridDeg;
    currentResult.axes.x_m = xAxisM;
    currentResult.axes.y_m = yAxisM;
    currentResult.axes.z_m = zAxisM;
    currentResult.validAngleMask = validAngleMask;
    currentResult.polarCube = polarCompressed;
    currentResult.cartesianCube = cartesianCube;
    currentResult.fourDCube = fourDCube;
    currentResult.fourDCubeOrder = {'doppler', 'range', 'elevation', 'azimuth'};

    if cfg.plotOn
        plotResultPreview(currentResult);
    end

    if cfg.saveOutput
        outputFile = resolveOutputFile(cfg.outputFile, cfg.outputRootDir, scriptDir, dataFolderTest, groupIdx, cfg.frameIdx, numel(fileGroupIndices) > 1);
        outputFolder = fileparts(outputFile);
        if exist(outputFolder, 'dir') ~= 7
            mkdir(outputFolder);
        end
        resultToSave = currentResult; %#ok<NASGU>
        % Keep a legacy-friendly top-level export while preserving the full result struct.
        % old_data used a top-level heatmap_ct variable, so keep that name here.
        bev_grid = double(currentResult.cartesianCube); %#ok<NASGU>
        heatmap_ct = double(currentResult.polarCube); %#ok<NASGU>
        save(outputFile, 'resultToSave', 'bev_grid', 'heatmap_ct', '-v7');
        currentResult.outputFile = outputFile;
    else
        currentResult.outputFile = '';
    end

    fprintf('Processed folder %s, frame %d, file group %d.\n', dataFolderTest, cfg.frameIdx, groupIdx);
    fprintf('Internal 4D size: [%d Doppler, %d Range, %d Elevation, %d Azimuth]\n', ...
        numDopplerBins, numRangeBins, DOAObj.DOAFFTSize, DOAObj.DOAFFTSize);

    fileGroupResultsCell{groupPos} = currentResult;
end

if numel(fileGroupResultsCell) == 1
    fileGroupResults = fileGroupResultsCell{1};
    singleResult = fileGroupResultsCell{1};
else
    fileGroupResults = [fileGroupResultsCell{:}];
    singleResult = [];
end

results = struct();
results.captureFolder = dataFolderTest;
results.configJsonFileUsed = configJsonFile;
results.generatedParamFile = generatedParamFile;
results.fileGroups = fileGroupResults;
if ~isempty(singleResult)
    results.single = singleResult;
end
end

function outputFile = resolveOutputFile(requestedOutputFile, outputRootDir, scriptDir, dataFolderTest, fileGroupIdx, frameIdx, includeFolderName)
if ~isempty(requestedOutputFile)
    if includeFolderName
        [folderPath, baseName, ext] = fileparts(requestedOutputFile);
        if isempty(ext)
            ext = '.mat';
        end
        captureName = getLastPathPart(dataFolderTest);
        outputFile = fullfile(folderPath, sprintf('%s_%s_group%d_frame%d%s', baseName, captureName, fileGroupIdx, frameIdx, ext));
    else
        outputFile = requestedOutputFile;
    end
    return;
end

captureName = getLastPathPart(dataFolderTest);
baseOutputDir = outputRootDir;
if isempty(baseOutputDir)
    baseOutputDir = fullfile(scriptDir, 'output');
end
outputFile = fullfile(baseOutputDir, sprintf('cascade4D_%s_group%d_frame%d.mat', captureName, fileGroupIdx, frameIdx));
end

function part = getLastPathPart(folderPath)
[~, part] = fileparts(folderPath);
end

function configJsonFile = resolveConfigJsonFile(configJsonFile, dataFolderTest, scriptDir)
if ~isempty(configJsonFile)
    if exist(configJsonFile, 'file') ~= 2
        error('configJsonFile not found: %s', configJsonFile);
    end
    return;
end

jsonFiles = dir(fullfile(dataFolderTest, '*.mmwave.json'));
if numel(jsonFiles) > 1
    error('Multiple *.mmwave.json files found in %s. Please pass configJsonFile explicitly.', dataFolderTest);
elseif numel(jsonFiles) == 1
    configJsonFile = fullfile(dataFolderTest, jsonFiles(1).name);
    return;
end

defaultConfigJsonFile = fullfile(scriptDir, 'config', 'default_cascade.mmwave.json');
if exist(defaultConfigJsonFile, 'file') == 2
    configJsonFile = defaultConfigJsonFile;
else
    configJsonFile = '';
end
end

function createParamFileFromJsonConfig(configJsonFile, dataFolderCalib, moduleParamFile, outputParamFile, dataPlatform)
paramsChirp = JsonParser(configJsonFile);
numChirpConfig = length(paramsChirp.DevConfig(1).Chirp);
numTXPerDev = 3;
totTx = numTXPerDev * paramsChirp.NumDevices;
TxEnableTable = zeros(numChirpConfig, totTx);

for iDev = 1:paramsChirp.NumDevices
    for iconfig = 1:numChirpConfig
        TxEnableTable(iconfig, 1 + (iDev - 1) * numTXPerDev) = paramsChirp.DevConfig(iDev).Chirp(iconfig).Tx0Enable;
        TxEnableTable(iconfig, 2 + (iDev - 1) * numTXPerDev) = paramsChirp.DevConfig(iDev).Chirp(iconfig).Tx1Enable;
        TxEnableTable(iconfig, 3 + (iDev - 1) * numTXPerDev) = paramsChirp.DevConfig(iDev).Chirp(iconfig).Tx2Enable;
    end
end

TxChannelEnabled = zeros(1, numChirpConfig);
for iconfig = 1:numChirpConfig
    channelID = find(TxEnableTable(iconfig, :) ~= 0);
    if isempty(channelID)
        error('No enabled TX found for chirp index %d in %s', iconfig, configJsonFile);
    end
    if numel(channelID) ~= 1
        error('Expected exactly one active TX for chirp index %d, found %d in %s', iconfig, numel(channelID), configJsonFile);
    end
    TxChannelEnabled(iconfig) = channelID(1);
end

profile = paramsChirp.DevConfig(1).Profile(1);
frameCfg = paramsChirp.DevConfig(1).FrameConfig;
numChirpsInLoop = frameCfg.ChirpEndIdx - frameCfg.ChirpIdx + 1;
if numChirpsInLoop ~= paramsChirp.DevConfig(1).NumChirps
    warning('FrameConfig chirp count (%d) differs from parser chirp count (%d). Using FrameConfig value.', ...
        numChirpsInLoop, paramsChirp.DevConfig(1).NumChirps);
end
loadedCalib = load(dataFolderCalib, 'params');
paramsCalib = loadedCalib.params;

fidParam = fopen(outputParamFile, 'w');
if fidParam < 0
    error('Unable to create parameter file: %s', outputParamFile);
end
cleanupObj = onCleanup(@() fclose(fidParam)); %#ok<NASGU>

headerPath = fullfile(fileparts(moduleParamFile), 'header.m');
if exist(headerPath, 'file') ~= 2
    headerPath = fullfile(fileparts(fileparts(moduleParamFile)), 'paramGen', 'header.m');
end
if exist(headerPath, 'file') == 2
    fwrite(fidParam, fileread(headerPath));
    fprintf(fidParam, '\n\n\n');
end

fprintf(fidParam, 'ADVANCED_FRAME_CONFIG = 0; \n');
fprintf(fidParam, 'dataPlatform = ''%s''; \n', dataPlatform);
fprintf(fidParam, '%%pass the chirp parameters associated with test data \n');
fprintf(fidParam, 'numADCSample = %e; \n', profile.NumSamples);
fprintf(fidParam, 'adcSampleRate = %e; %%Hz/s \n', profile.SamplingRate * 1e3);
fprintf(fidParam, 'startFreqConst = %e; %%Hz \n', profile.StartFreq * 1e9);
fprintf(fidParam, 'chirpSlope = %e; %%Hz/s \n', profile.FreqSlope * 1e12);
fprintf(fidParam, 'chirpIdleTime = %e; %%s \n', profile.IdleTime * 1e-6);
fprintf(fidParam, 'adcStartTimeConst = %e; %%s \n', profile.AdcStartTime * 1e-6);
fprintf(fidParam, 'chirpRampEndTime = %e; %%s \n', profile.RampEndTime * 1e-6);
fprintf(fidParam, 'framePeriodicty = %e; \n', frameCfg.Periodicity * 1e-3);
fprintf(fidParam, 'NumDevices = %d; \n', paramsChirp.NumDevices);
fprintf(fidParam, 'frameCount = %e; %%s \n', frameCfg.NumFrames);
fprintf(fidParam, 'numChirpsInLoop = %e; %%s \n', numChirpsInLoop);
fprintf(fidParam, 'nchirp_loops = %d; \n', frameCfg.NumChirpLoops);
fprintf(fidParam, 'numTxAnt = %d; \n', length(paramsChirp.TxToEnable));
fprintf(fidParam, ['TxToEnable = [' num2str(TxChannelEnabled) '];\n']);
fprintf(fidParam, 'numRxToEnable = %d; \n', length(paramsChirp.RxToEnable));
startFreqHz = profile.StartFreq * 1e9;
sampleRateHz = profile.SamplingRate * 1e3;
slopeHzPerSec = profile.FreqSlope * 1e12;
chirpDurationSec = profile.NumSamples / sampleRateHz;
centerFreqHz = startFreqHz + slopeHzPerSec * chirpDurationSec / 2;
centerFreqGHz = centerFreqHz / 1e9;
if centerFreqGHz < 77 || centerFreqGHz > 81
    warning('Computed centerFreq is %.4f GHz, outside the expected 77-81 GHz band.', centerFreqGHz);
end
fprintf(fidParam, 'centerFreq = %e; \n', centerFreqGHz);
fprintf(fidParam, '%%pass the slope used for calibration \n');
fprintf(fidParam, 'Slope_calib = %e; \n\n', paramsCalib.Slope_MHzperus * 1e12);
fprintf(fidParam, 'fs_calib = %e; \n\n', paramsCalib.Sampling_Rate_sps);
fprintf(fidParam, '%%pass all other parameters \n');

moduleText = fileread(moduleParamFile);
lineBreaks = regexp(moduleText, '\r\n|\n|\r', 'split');
if numel(lineBreaks) > 32
    moduleText = strjoin(lineBreaks(33:end), sprintf('\n'));
end
fwrite(fidParam, moduleText);
end

function [dataFolderTest, dataFolderCalib, moduleParamFile] = getTestEntry(testListPath, testID)
fid = fopen(testListPath, 'r');
if fid < 0
    error('Unable to open %s', testListPath);
end
cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>

entries = {};
lines = {};
while ~feof(fid)
    line = strtrim(fgetl(fid));
    if ischar(line) && ~isempty(line)
        lines{end+1} = line; %#ok<AGROW>
    end
end

if mod(numel(lines), 3) ~= 0
    error('testList.txt must contain non-empty entries in groups of 3 lines.');
end

for idx = 1:3:numel(lines)
    entries(end+1, :) = lines(idx:idx+2); %#ok<AGROW>
end

if testID < 1 || testID > size(entries, 1)
    error('testID=%d is out of range. Available tests: 1..%d', testID, size(entries, 1));
end

dataFolderTest = entries{testID, 1};
dataFolderCalib = entries{testID, 2};
moduleParamFile = entries{testID, 3};
end

function [linIdxKeep, apertureLenAz, apertureLenEl, keepMask] = buildVirtualArrayMap(D)
D = D + 1;
apertureLenAz = max(D(:, 1));
apertureLenEl = max(D(:, 2));
keepMask = false(size(D, 1), 1);

for elevIdx = 1:apertureLenEl
    lineIdx = find(D(:, 2) == elevIdx);
    [~, uniqueIdx] = unique(D(lineIdx, 1), 'stable');
    keepMask(lineIdx(uniqueIdx)) = true;
end

Dkeep = D(keepMask, :);
linIdxKeep = sub2ind([apertureLenAz, apertureLenEl], Dkeep(:, 1), Dkeep(:, 2));
end

function [azimuthGridDeg, elevationGridDeg, validMask] = buildAngleGrid(angleFFTSize, antDis, azFovDeg, elFovDeg)
wxVec = linspace(-pi, pi, angleFFTSize + 1);
wxVec = wxVec(1:end-1);
wzVec = wxVec;
elevVec = asind(wzVec / (2 * pi * antDis));

[wxGrid, wzGrid] = ndgrid(wxVec, wzVec);
elevationGridDegAzEl = asind(wzGrid / (2 * pi * antDis));

azimuthGridDegAzEl = nan(size(elevationGridDegAzEl));
azSin = (wxGrid / (2 * pi * antDis)) ./ cosd(elevationGridDegAzEl);
validSin = abs(azSin) <= 1;
azimuthGridDegAzEl(validSin) = asind(azSin(validSin));

validMask = validSin & ...
            azimuthGridDegAzEl >= azFovDeg(1) & azimuthGridDegAzEl <= azFovDeg(2) & ...
            elevationGridDegAzEl >= elFovDeg(1) & elevationGridDegAzEl <= elFovDeg(2);

azimuthGridDeg = azimuthGridDegAzEl.';
elevationGridDeg = elevationGridDegAzEl.';
validMask = validMask.';
end

function compressedMap = compressDoppler(powerCube, method)
switch lower(method)
    case 'sum'
        compressedMap = sum(powerCube, 3);
    case 'max'
        compressedMap = max(powerCube, [], 3);
    case 'mean'
        compressedMap = mean(powerCube, 3);
    otherwise
        error('Unsupported dopplerCompressMethod: %s. Use sum, max, or mean.', method);
end
end

function [cartesianCube, xAxisM, yAxisM, zAxisM] = polarToCartesian( ...
    polarCube, rangeAxisM, azimuthGridDeg, elevationGridDeg, cartGridSize)

maxRange = max(rangeAxisM);
validAz = azimuthGridDeg(~isnan(azimuthGridDeg));
validEl = elevationGridDeg(~isnan(elevationGridDeg));

if isempty(validAz)
    validAz = 0;
end
if isempty(validEl)
    validEl = 0;
end

maxAbsX = maxRange * sind(max(abs(validAz))) * cosd(min(abs(validEl)));
maxY = maxRange;
maxAbsZ = maxRange * sind(max(abs(validEl)));

xAxisM = linspace(-maxAbsX, maxAbsX, cartGridSize(1));
yAxisM = linspace(0, maxY, cartGridSize(2));
zAxisM = linspace(-maxAbsZ, maxAbsZ, cartGridSize(3));

xEdges = axisToEdges(xAxisM);
yEdges = axisToEdges(yAxisM);
zEdges = axisToEdges(zAxisM);

cartesianVec = zeros(prod(cartGridSize), 1, 'single');

for rangeIdx = 1:size(polarCube, 1)
    radius = rangeAxisM(rangeIdx);
    slice = squeeze(polarCube(rangeIdx, :, :));

    x = radius * sind(azimuthGridDeg) .* cosd(elevationGridDeg);
    y = radius * cosd(azimuthGridDeg) .* cosd(elevationGridDeg);
    z = radius * sind(elevationGridDeg);

    xIdx = discretize(x(:), xEdges);
    yIdx = discretize(y(:), yEdges);
    zIdx = discretize(z(:), zEdges);

    valid = ~isnan(xIdx) & ~isnan(yIdx) & ~isnan(zIdx);
    if ~any(valid)
        continue;
    end

    linIdx = sub2ind(cartGridSize, xIdx(valid), yIdx(valid), zIdx(valid));
    values = single(slice(valid));
    sliceVec = accumarray(linIdx, values, [prod(cartGridSize), 1], @max, single(0));
    cartesianVec = max(cartesianVec, sliceVec);
end

cartesianCube = reshape(cartesianVec, cartGridSize);
end

function edges = axisToEdges(axisVals)
delta = diff(axisVals);
if isempty(delta)
    edges = [axisVals(1)-0.5, axisVals(1)+0.5];
    return;
end
edges = zeros(1, numel(axisVals) + 1);
edges(2:end-1) = axisVals(1:end-1) + delta / 2;
edges(1) = axisVals(1) - delta(1) / 2;
edges(end) = axisVals(end) + delta(end) / 2;
end

function values = readParamFileValues(paramFile, varNames)
run(paramFile);
values = struct();
for idx = 1:numel(varNames)
    currentName = varNames{idx};
    if exist(currentName, 'var') ~= 1
        error('Variable %s was not found in %s', currentName, paramFile);
    end
    values.(currentName) = eval(currentName);
end
end

function plotResultPreview(results)
polarCube = results.polarCube;
cartCube = results.cartesianCube;
rangeProfile = squeeze(max(max(polarCube, [], 3), [], 2));
azProjection = squeeze(max(polarCube, [], 1));
xyProjection = squeeze(max(cartCube, [], 3));

figure;
subplot(1, 3, 1);
plot(results.axes.range_m, 10 * log10(double(rangeProfile) + 1));
grid on;
xlabel('Range (m)');
ylabel('Power (dB)');
title('Compressed Range Profile');

subplot(1, 3, 2);
imagesc(10 * log10(double(azProjection) + 1));
axis xy;
xlabel('Azimuth Bin');
ylabel('Elevation Bin');
title('Polar Cube Max Projection');
colorbar;

subplot(1, 3, 3);
imagesc(results.axes.x_m, results.axes.y_m, 10 * log10(double(xyProjection.') + 1));
axis xy;
xlabel('X (m)');
ylabel('Y (m)');
title('Cartesian XY Projection');
colorbar;
end

