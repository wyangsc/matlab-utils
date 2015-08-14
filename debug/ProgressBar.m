classdef ProgressBar < handle
% Generates a progress bar which uses ANSI color codes to colorize output
% in a color terminal. The background color steadily advances along from 
% left to right beneath a custom message and progress percentage string.
%
% Parallel mode: this class works in spmd and parfor blocks, if
% .enableParallel is called BEFORE the spmd/parfor block. Only the thread
% with labindex==1 will output to the screen. 
%
% Usage:
%   pbar = ProgressBar('Message goes here', nThingsToProcess);
%   for i = 1:nThingsToProcess
%       pbar.update(i, [optional message update]);
%       ...
%   end
%   pbar.finish([optional final message]);
%
% Parallel usage: (sort of works)
%   pbar = ProgressBar('Message goes here', nThingsToProcess);
%   pbar.enableParallel();
%   for i = 1:nThingsToProcess
%       ... % put operations BEFORE update
%       pbar.update(i, [optional message update]);
%   end
%   pbar.finish([optional final message]);
%         
% Demonstration:
%   ProgressBar.demo();
%   ProgressBar.demoNested();
%   ProgressBar.demoParallel();
%
%   

    properties(SetAccess=protected)
        message
        N
        cols
        trueColor = false;
        firstUpdate  
        timeStart
        
        usingTerminal

        % enable for parallel for loops? see .enableParallel / disableParallel
        parallel = false;
        fnamePrefix
        
        objWorker
        
        nCompleteByWorker
        
        lastNBoxes = 0;
        lastNSpaces = 0;
        
        trueCmap;
    end

    methods
        function pbar = ProgressBar(N, message, varargin)
            if nargin > 1
                pbar.message = sprintf(message, varargin{:});
            else
                pbar.message = '';
            end
            
            if nargin >= 2
                pbar.N = N;
            else
                pbar.N = 1;
            end
            
            pbar.usingTerminal = ~usejava('desktop');
            
            [~, pbar.cols] = ProgressBar.getTerminalSize();
            pbar.trueColor = ~isempty(getenv('ITERM_PROFILE')) && false;
            
            if pbar.trueColor
                hsv = ones(pbar.cols, 3);
                hsv(:, 1) = 0.5;
                hsv(:, 2) = 0.6;
                b = 0.5 * (1+sin((1:pbar.cols) / 8));
                x = 0.3;
                b = b*x + 0.95-x;
                hsv(:, 3) = b;
                pbar.trueCmap = round(256*hsv2rgb(hsv));
            end
            
            pbar.firstUpdate = true;
            pbar.timeStart = now;
            pbar.lastNBoxes = 0;
            pbar.lastNSpaces = 0;
            pbar.update(0);
        end
        
        function enableParallel(pbar)
            pbar.parallel = true;
            pbar.fnamePrefix = tempname();
            try
                delete(sprintf('%s_*', pbar.fnamePrefix));
            catch
            end
            
            pbar.objWorker = WorkerObjWrapper(@labindex, {});
        end

        function n = updateParallel(pbar, n)           
            id = pbar.objWorker.Value;
            if ~isscalar(id)
                % not running in parallel mode
                % n = n;
                return;
            end
            fname = sprintf('%s_%d', pbar.fnamePrefix, id);
            f = fopen(fname, 'a');
            fprintf(f, '.');
            fclose(f);
            
            if id == 1
                % i do all output
                d = dir([pbar.fnamePrefix '_*']);
                n = sum([d.bytes]); 
            else
                % non-primary worker, no output
                n = [];
            end
        end
        
        function cleanupParallel(pbar)
            if pbar.parallel
                delete(sprintf('%s_*', pbar.fnamePrefix));
            end
        end
        
        function update(pbar, n, message, varargin)
            if nargin > 2
                newMessage = true;
                pbar.message = sprintf(message, varargin{:});
            else
                newMessage = false;
            end
            
            if pbar.firstUpdate
                newMessage = true;
                firstUpdate = true;
                pbar.firstUpdate = false;
            else
                firstUpdate = false;
            end
            
            if pbar.N > 0
                numWidth = ceil(log10(pbar.N));
            else
                numWidth = 1;
            end

            if pbar.parallel
                n = pbar.updateParallel(n);
                if isempty(n)
                    return;
                end
            end
            
            if n < 0
                n = 0;
            end
            if isempty(pbar.N) || pbar.N == 1
                ratio = n;
                if ratio < 0
                    ratio = 0;
                end
                if ratio > 1
                    ratio = 1;
                end
                percentage = ratio * 100;
                progStr = sprintf('[ %5.1f%% ]', percentage);
                %progLen = 10;
            else
                ratio = (n-1)/pbar.N;
                percentage = min(max(ratio*100, 0), 100);
                progStr = sprintf('%*d / %*d [ %5.1f%% ]', numWidth, n, numWidth, pbar.N, percentage);
                
                %progLen = numWidth*2 + 4 + 10;
            end
            
            progLen = length(progStr);
            
            if ratio < 0
                ratio = 0;
            end
            if ratio > 1
                ratio = 1;
            end
            
            if length(pbar.message) + progLen + 3 > pbar.cols
                message = [pbar.message(1:(pbar.cols - progLen - 6)), '...'];
            else
                message = pbar.message;
            end 
            
            gap = pbar.cols - 1 - (length(message)+1) - progLen;
            spaces = repmat(' ', 1, gap);
            if pbar.usingTerminal
                str = [message spaces progStr]; 
            else
                str = [message spaces blanks(numel(progStr))];
            end

            % separate into colored portion of bar and non-colored portion of bar
            ind = min(length(str), ceil(ratio*pbar.cols));
            preStr = str(1:ind);
            postStr = str(ind+1:end);

            % try using 24 color
            if pbar.trueColor
                newPreStr = '';
                for i = 1:numel(preStr)
                    color = pbar.trueCmap(i, :);
%                     color = pbar.trueCmap(mod(i-1, size(pbar.trueCmap, 1))+1, :);
                    newPreStr = [newPreStr, sprintf('\x1b[48;2;%d;%d;%dm%s' , color, preStr(i))];
                end
                preStr = newPreStr;
            end
            
            try
                DatabaseAnalysis.pauseOutputLog();
            catch
            end
            
%            disp(n)
            if pbar.usingTerminal
                if pbar.parallel
                    fprintf('\033[1A\033[1;44;37m %s\033[49;37m%s\033[0m \n', preStr, postStr);
                else
                    if firstUpdate
                        fprintf(' '); % don't delete whole line on first update
                    end
                    if pbar.trueColor
                        fprintf('\b\r%s\033[49;37m%s\033[0m ', preStr, postStr);
                    else
                        fprintf('\b\r\033[1;44;37m %s\033[49;37m%s\033[0m ', preStr, postStr);
                    end
                end
            else
                % figure out number of boxes
                boxChar = char(9608);
                nTotal = pbar.cols - 4;
                idealBoxCount = ratio*(nTotal-numel(progStr)-2);
                nBoxes = floor(idealBoxCount);
                
                nBoxesLast = pbar.lastNBoxes;
                newBoxes = nBoxes - nBoxesLast;
                nSpaces = nTotal-nBoxes;
                boxes = repmat(boxChar, 1, newBoxes);
                
                fracLast = idealBoxCount - nBoxes;
                fractionalBox = ProgressBar.getFractionalBlockChar(fracLast);
                
                empty = blanks(nSpaces);
                empty((end-numel(progStr)+1):end) = progStr;
                
                % clear old lines
                if ~firstUpdate
                    if newMessage
                        backspaces = repmat('\b', 1, pbar.lastNSpaces + pbar.lastNBoxes + 1 + pbar.cols - 1);
                    else
                        % no need to update message, clear only the number
                        % of boxes required
                        backspaces = repmat('\b', 1, pbar.lastNSpaces + 1);
                    end
                    fprintf(backspaces);
                end
                
                pbar.lastNBoxes = nBoxes;
                pbar.lastNSpaces = nSpaces;
                
                
                if newMessage
                    fprintf('%s%s\n', preStr, postStr);
                end
                
                fprintf('%s%c%s', boxes, fractionalBox, empty);
                
            end
            
            try
                DatabaseAnalysis.resumeOutputLog();
            catch
            end
            %str = sprintf('\b\r\033[1;44;37m %s\033[49;37m%s\033[0m ', preStr, postStr);
            %disp(str);
            
        end

        function finish(pbar, message, varargin)
            % if message is provided (also in printf format), the message
            % will be displayed. Otherwise, the progress bar will disappear
            % and output will resume on the same line.
            
            %gap = pbar.cols - 1 - length(pbar.message);
            %spaces = repmat(' ' , 1, gap);
            %fprintf('\b\r%s%s\033[0m\n', pbar.message, spaces);

            try
                DatabaseAnalysis.pauseOutputLog();
            catch
            end
            
            if pbar.usingTerminal
                spaces = repmat(' ', 1, pbar.cols-1);
                if pbar.parallel
                    fprintf('\033[1A%s\033[0m\r', spaces);
                else
                    fprintf('\b\r%s\033[0m\r', spaces);
                end
            else
                backspaces = repmat('\b', 1, pbar.lastNSpaces + pbar.lastNBoxes + 1 + pbar.cols - 1);
                fprintf(backspaces);
            end
            if nargin > 1
                pbar.message = sprintf(message, varargin{:});
                fprintf('%s\n', pbar.message);
            end
            
            %if pbar.parallel && exist(pbar.fname, 'file')
                %delete(pbar.fname);
            %end
            
            pbar.cleanupParallel();
            
            try
                DatabaseAnalysis.resumeOutputLog();
            catch
            end
        end
    end

    methods(Static)
        function demo(N, varargin)
            if nargin < 1
                N = 300;
            end
            if numel(varargin) == 0
                varargin = {'Running ProgressBarDemo with %d items', N};
            end
            
            pbar = ProgressBar(N, varargin{:});
            for i = 1:N
                pbar.update(i);
%                 if i == floor(N/2) && withInterruption
%                     fprintf('Random interruption!\n');
%                 end
                pause(0.01);
            end
            pbar.finish();
        end
        
        function demoNested()
            ni = 20;
            nj = 100;

            pi = ProgressBar(ni, 'Outer loop');
            for i = 1:ni
                pi.update(i);
                pj = ProgressBar(nj, 'Inner loop');
                for j = 1:nj
                    pj.update(j);
                    pause(0.001);
                end
                pj.finish();
            end
            pi.finish();
        end
        
        function demoParallel(N, varargin)
            if nargin < 1
                N = 100;
            end
            if numel(varargin) == 0
                varargin = {'Running ProgressBarDemo parallel with %d items', N};
            end
            
            pbar = ProgressBar(N, varargin{:});
            pbar.enableParallel();

            parfor i = 1:N
                pause(0.3*rand(1));
                pbar.update(i); %#ok<PFBNS>
            end
            pbar.finish();
        end
        
        function [rows, cols] = getTerminalSize()
            usingTerminal = ~usejava('desktop');

            % use sensible defaults
            rows = 24;
            cols = 80;

            if (ismac || isunix) && usingTerminal
                % actual terminal: get terminal width using tput
                cmd = 'tput lines';
                [~, r] = unix(cmd);
                num = sscanf(r, '%d');
                if ~isempty(num)
                    rows = num;
                end

                cmd = 'tput cols';
                [~, r] = unix(cmd);
                num = sscanf(r, '%d');
                if ~isempty(num)
                    cols = num;
                end

            elseif ~usingTerminal %#ok<*PROP
                % matlab command window size
                try
                    jDesktop = com.mathworks.mde.desk.MLDesktop.getInstance;
                    cmdWin = jDesktop.getClient('Command Window');

                    jTextArea = cmdWin.getComponent(0).getViewport.getComponent(0);
                    height = jTextArea.getHeight();
                    width = jTextArea.getParent.getWidth();
                    font = jTextArea.getParent().getFont();
                    metrics = cmdWin.getFontMetrics(font);
                    charWidth = metrics.charWidth('A');
                    charHeight = metrics.getHeight();

                    rows = floor(height/charHeight);
                    cols = floor(width/charWidth);
                catch
                end
            end
        end
        
        function ch = getFractionalBlockChar(frac)
            if frac < 1/8
                ch = char(' ');
            elseif frac < 1
                ch = char(9614 - floor(frac / 0.125));
            end
        end
    end
end
