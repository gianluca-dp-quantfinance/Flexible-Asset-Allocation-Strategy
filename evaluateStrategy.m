function metrics = evaluateStrategy(returns, benchmark, rf)
% ==========================================================
% Calcola metriche di performance per una serie di rendimenti mensili
% ==========================================================
%
% INPUT:
%   returns   : vettore rendimenti mensili (log returns) della strategia
%   benchmark : vettore rendimenti mensili del benchmark (es. EW)
%   rf        : (opzionale) vettore rendimenti mensili risk-free (es. W1G1)
%
% OUTPUT:
%   metrics : struct con tutte le metriche calcolate
%
% ==========================================================

    % =====================
    % 1. Allineamento e pulizia iniziale
    % =====================
    if nargin < 3 || isempty(rf)
        rf = zeros(size(returns));   % default: risk-free = 0
    end

    returns   = returns(:);
    benchmark = benchmark(:);
    rf        = rf(:);

    n = min([length(returns), length(benchmark), length(rf)]);
    returns   = returns(1:n);
    benchmark = benchmark(1:n);
    rf        = rf(1:n);

    mask_all = isfinite(returns) & isfinite(benchmark) & isfinite(rf);
    returns   = returns(mask_all);
    benchmark = benchmark(mask_all);
    rf        = rf(mask_all);

    rets = returns;   % alias per coerenza con la versione precedente

    % =====================
    % 2. CAGR
    % =====================
    V_start = 1;
    mean_log_ret = mean(rets, 'omitnan');
    CAGR = exp(mean_log_ret * 12) - 1;
    V_end = V_start * exp(sum(rets));

    % =====================
    % 3. Annualized Return & Volatility
    % =====================
    ann_return = mean(rets) * 12;
    ann_vol    = std(rets) * sqrt(12);

    % =====================
    % 4. Sharpe Ratio (rf reale)
    % =====================
    sharpe = (mean(rets - rf) / std(rets) * sqrt(12));

    % =====================
    % 5. Sortino Ratio (MAR = 5%)
    % =====================
    MAR = (1+0.05)^(1/12) - 1; % tasso minimo di rendimento accettabile
    downside_diff = rets - MAR;
    downside_dev  = std(downside_diff(downside_diff < 0));
    if isempty(downside_dev) || downside_dev == 0
        sortino = NaN;
    else
        sortino = (mean(rets - MAR) / downside_dev) * sqrt(12);
    end
      % =====================
    % 5b. Sortino Ratio Modificato (Omega version)
    % =====================
    rneg = rets(rets < 0);  % rendimenti negativi
    if isempty(rneg)
        sortino_mod = NaN;
    else
        avgNeg = mean(rneg, 'omitnan');    % media rendimenti negativi
        stdNeg = std(rneg, 'omitnan');     % deviazione standard rendimenti negativi
        D = mean([abs(avgNeg), stdNeg]);   % rischio negativo composito
        mu = mean(rets, 'omitnan');        % rendimento medio
        sortino_mod = mu / max(D, eps);    % Sortino modificato
    end

    % =====================
    % 6. Worst Drawdown
    % =====================
    eq_curve = exp(cumsum(rets));
    peak = cummax(eq_curve);
    dd = (eq_curve - peak) ./ peak;
    worst_dd = min(dd);

    % =====================
    % 6b. Calmar Ratio
    % =====================
    if worst_dd ~= 0
        calmar = CAGR / abs(worst_dd);
    else
        calmar = NaN;
    end

    % =====================
    % 6c. Robust Index (Omega version)
    % =====================

    % Escludo outlier positivi (taglio al 99° percentile)
    thr = prctile(rets, 99);
    r_trim = rets(rets <= thr);

    % Rendimento cumulato "trimmed"
    nav_trim = [1; cumprod(1 + r_trim)];
    CumRet_excl = nav_trim(end) - 1;

    % Identifico periodi underwater (in drawdown)
    inDD = eq_curve < cummax(eq_curve);
    runs = diff([0; inDD; 0]);
    sIdx = find(runs == 1);       % start index dei drawdown
    eIdx = find(runs == -1) - 1;  % end index dei drawdown

    lengths = eIdx - sIdx + 1;    % durata di ciascun drawdown
    if isempty(lengths)
        MaxUW = 0; 
        AvgUW = 0;
    else
        MaxUW = max(lengths);
        AvgUW = mean(lengths);
    end

    % Denominatore = media tra durata massima e media dei drawdown
    denomUW = mean([MaxUW, AvgUW]);

    % Robust Index finale
    if denomUW == 0
        robust_idx = Inf;
    else
        robust_idx = CumRet_excl / denomUW;
    end
  
    % ====================
    % 7. VaR / Expected Shortfall
    % ====================
    alpha = 0.05;                           % livello di confidenza
    VaR_5 = quantile(rets, alpha);          % empirico (storico)
    ES_5  = mean(rets(rets <= VaR_5));      % expected shortfall (conditional VaR)

    % =====================
    % 7. Best / Worst Month
    % =====================
    best_month  = max(rets);
    worst_month = min(rets);

    % =====================
    % 8. Profitable Months
    % =====================
    profitable_months = sum(rets > 0) / length(rets);

    % =====================
    % 9. Rolling Win %
    % =====================
    roll1y_win  = rollingWinPct(rets, 12);
    roll5y_win  = rollingWinPct(rets, 60);
    roll10y_win = rollingWinPct(rets, 120);

    % =====================
    % 10. Sum (5-Year Rolling MaxDD)
    % =====================
    roll5y_maxdd = rollingMaxDD(eq_curve, 60);
    sum_roll5y_maxdd = sum(roll5y_maxdd);

    % =====================
    % 11. Correlation Analysis (con benchmark)
    % =====================
    if all(benchmark == 0)
        UpPct        = NaN;
        DownPct      = NaN;
        NegCorr      = NaN;
        PosCorr      = NaN;
        TrackingErr  = NaN;
    else
        mask_bench = ~isnan(benchmark) & ~isnan(rets);
        rb = benchmark(mask_bench);
        rp = rets(mask_bench);

        upIdx   = rb > 0;
        downIdx = rb < 0;

        if any(upIdx)
            UpPct = 100 * sum(rp(upIdx) > 0) / sum(upIdx);
        else
            UpPct = NaN;
        end

        if any(downIdx)
            DownPct = 100 * sum(rp(downIdx) < 0) / sum(downIdx);
        else
            DownPct = NaN;
        end

        if sum(downIdx) > 2
            NegCorr = corr(rp(downIdx), rb(downIdx), 'rows','complete') * 100;
        else
            NegCorr = NaN;
        end
        if sum(upIdx) > 2
            PosCorr = corr(rp(upIdx), rb(upIdx), 'rows','complete') * 100;
        else
            PosCorr = NaN;
        end

        TrackingErr = std(rp - rb, 'omitnan') * sqrt(12) * 100;
    end

    % =====================
    % 12. Output struct
    % =====================
    metrics = struct();
    metrics.CAGR              = CAGR;
    metrics.AnnualizedReturn  = ann_return;
    metrics.ExcessAnnReturn   = mean(rets - rf) * 12; 
    metrics.AnnualizedVol     = ann_vol;
    metrics.Sharpe            = sharpe;
    metrics.Sortino           = sortino;
    metrics.DownsideDev       = downside_dev;
    metrics.WorstDrawdown     = worst_dd;
    metrics.Calmar            = calmar;
    metrics.SortinoMod = sortino_mod;
    metrics.Robust = robust_idx;
    metrics.VaR_5pct          = VaR_5;
    metrics.ES_5pct           = ES_5;
    metrics.BestMonth         = best_month;
    metrics.WorstMonth        = worst_month;
    metrics.ProfitableMonths  = profitable_months;
    metrics.Rolling1YWinPct   = roll1y_win;
    metrics.Rolling5YWinPct   = roll5y_win;
    metrics.Rolling10YWinPct  = roll10y_win;
    metrics.Sum5YRollingMaxDD = sum_roll5y_maxdd;

    % Correlation Analysis
    metrics.UpCorrPct         = UpPct;
    metrics.DownCorrPct       = DownPct;
    metrics.NegativeCorrPct   = NegCorr;
    metrics.PositiveCorrPct   = PosCorr;
    metrics.TrackingErrorPct  = TrackingErr;

end


%% === Helper: rolling win % ===
function winPct = rollingWinPct(rets, window)
    eq = cumprod(1 + rets);
    win = 0; count = 0;
    for i = window:length(rets)
        r_window = eq(i) / eq(i-window+1) - 1;
        if r_window > 0
            win = win + 1;
        end
        count = count + 1;
    end
    if count == 0
        winPct = NaN;
    else
        winPct = win / count;
    end
end

%% === Helper: rolling max drawdown ===
function maxDDs = rollingMaxDD(eq_curve, window)
    maxDDs = [];
    for i = window:length(eq_curve)
        window_eq = eq_curve(i-window+1:i);
        peak = cummax(window_eq);
        dd = (window_eq - peak) ./ peak;
        maxDDs(end+1) = min(dd);
    end
end
