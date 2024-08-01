// SPDX-License-Identifier: GPL
pragma solidity 0.8.26;

contract PolygonInitializable {
    bool inited;

    modifier polygonInitializer() {
        require(!inited, "already inited");
        _;
        inited = true;
    }
}
