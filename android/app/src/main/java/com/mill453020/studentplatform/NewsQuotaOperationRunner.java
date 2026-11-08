package com.mill453020.studentplatform;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.Future;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** Standalone synthetic runner; not registered with ordinary Flutter runtime. */
final class NewsQuotaOperationRunner {
    private static final ThreadPoolExecutor WORKER = new ThreadPoolExecutor(1, 1, 0,
            TimeUnit.MILLISECONDS, new ArrayBlockingQueue<>(16),
            new ThreadPoolExecutor.AbortPolicy());
    private NewsQuotaOperationRunner() {}

    private enum Phase { QUEUED, RUNNING, ACKED, EXPIRED }
    private static final class State {
        final long deadline;
        Phase phase = Phase.QUEUED;
        State(long deadline) { this.deadline = deadline; }
        synchronized boolean start() {
            if (phase != Phase.QUEUED || System.nanoTime() - deadline >= 0) { phase = Phase.EXPIRED; return false; }
            phase = Phase.RUNNING;
            return true;
        }
        synchronized void expire() { if (phase != Phase.ACKED) phase = Phase.EXPIRED; }
        synchronized NewsPrivateStoreFactory.ClearResult acknowledge(NewsPrivateStoreFactory factory,
                NewsPrivateStoreFactory.PendingClear receipt) {
            if (phase != Phase.RUNNING || System.nanoTime() - deadline >= 0) {
                phase = Phase.EXPIRED;
                return NewsPrivateStoreFactory.ClearResult.UNKNOWN;
            }
            final NewsPrivateStoreFactory.ClearResult result = factory.acknowledgeClear(receipt, this,
                    () -> phase == Phase.RUNNING && System.nanoTime() - deadline < 0);
            phase = System.nanoTime() - deadline >= 0 && result != NewsPrivateStoreFactory.ClearResult.CONFIRMED_HELD
                    ? Phase.EXPIRED : Phase.ACKED;
            return result;
        }
    }

    /** Call from a background observer. Timeout never cancels the raw worker. */
    static NewsPrivateStoreFactory.ClearResult clear(NewsPrivateStoreFactory factory, long timeoutMillis) {
        if (factory == null || timeoutMillis <= 0 || timeoutMillis > 60000) return NewsPrivateStoreFactory.ClearResult.UNKNOWN;
        final long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis);
        final State state = new State(deadline);
        // The local fence is raised synchronously before enqueue/rejection.
        final NewsPrivateStoreFactory.PreparedClear prepared = factory.prepareClearForMutationTesting(state);
        final Future<NewsPrivateStoreFactory.PendingClear> raw;
        try {
            raw = WORKER.submit(() -> state.start() ? factory.executePreparedClear(prepared, state) : null);
        } catch (RejectedExecutionException busy) { return NewsPrivateStoreFactory.ClearResult.UNKNOWN; }
        try {
            final long remaining = deadline - System.nanoTime();
            if (remaining <= 0) { state.expire(); return NewsPrivateStoreFactory.ClearResult.UNKNOWN; }
            final NewsPrivateStoreFactory.PendingClear receipt = raw.get(remaining, TimeUnit.NANOSECONDS);
            return state.acknowledge(factory, receipt);
        } catch (InterruptedException interrupted) {
            state.expire();
            Thread.currentThread().interrupt();
            return NewsPrivateStoreFactory.ClearResult.UNKNOWN;
        } catch (TimeoutException timeout) {
            state.expire();
            return NewsPrivateStoreFactory.ClearResult.UNKNOWN;
        } catch (Exception failure) {
            state.expire();
            return NewsPrivateStoreFactory.ClearResult.UNKNOWN;
        }
    }

    /** Isolated fixture helper; never interrupts the running operation. */
    static void awaitIdleForTesting() throws Exception {
        WORKER.submit(() -> {}).get(10, TimeUnit.SECONDS);
    }
}
