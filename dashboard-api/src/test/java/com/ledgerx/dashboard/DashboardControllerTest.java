package com.ledgerx.dashboard;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.Map;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class DashboardControllerTest {
    private LedgerReadService reads;
    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        reads = org.mockito.Mockito.mock(LedgerReadService.class);
        mvc = MockMvcBuilders.standaloneSetup(new DashboardController(reads))
                .setControllerAdvice(new ApiExceptionHandler()).build();
    }

    @Test
    void healthIsAReadOnlyGetRoute() throws Exception {
        when(reads.health()).thenReturn(Map.of("status", "ok", "database_role", "ledgerx_dashboard"));
        mvc.perform(get("/api/v1/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("ok"))
                .andExpect(jsonPath("$.database_role").value("ledgerx_dashboard"));
    }

    @Test
    void dashboardSummaryAcceptsDateFilters() throws Exception {
        when(reads.summary(any(), any())).thenReturn(Map.of("integrity_finding_count", 0));
        mvc.perform(get("/api/v1/dashboard/summary").param("from", "2026-01-01").param("to", "2026-01-31"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.integrity_finding_count").value(0));
    }

    @Test
    void noFinancialMutationRouteIsExposed() throws Exception {
        mvc.perform(post("/api/v1/transactions"))
                .andExpect(status().isMethodNotAllowed());
    }
}
