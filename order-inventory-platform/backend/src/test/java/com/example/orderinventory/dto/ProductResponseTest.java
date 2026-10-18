package com.example.orderinventory.dto;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import static org.assertj.core.api.Assertions.assertThat;

class ProductResponseTest {

    @ParameterizedTest(name = "stock {0} -> {1}")
    @CsvSource({
            "-1, OUT_OF_STOCK",
            "0, OUT_OF_STOCK",
            "1, LOW_STOCK",
            "10, LOW_STOCK",
            "11, IN_STOCK",
            "500, IN_STOCK"
    })
    void classifiesStockLevels(int stock, String expected) {
        assertThat(ProductResponse.calculateStatus(stock)).isEqualTo(expected);
    }

    @ParameterizedTest
    @CsvSource(value = {"null"}, nullValues = "null")
    void treatsUnknownStockAsOutOfStock(Integer stock) {
        assertThat(ProductResponse.calculateStatus(stock)).isEqualTo("OUT_OF_STOCK");
    }
}
